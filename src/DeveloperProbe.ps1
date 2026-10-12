function Get-WsmDeveloperProbeSafeAlias {
    param([Parameter(Mandatory)][string]$Value,[string]$Prefix='item',[string]$Salt='')
    $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($Salt+'|'+$Value.ToLowerInvariant())
    $hash=[Security.Cryptography.SHA256]::Create()
    try{$digest=([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
    $Prefix+'-'+$digest.Substring(0,12)
}

function ConvertTo-WsmDeveloperProbeSafeText {
    param([AllowNull()][string]$Value,[string]$Salt='')
    if($null -eq $Value){return $null}
    $safe=$Value
    # Replace recognizable secret material before path and hostname anonymization.
    $safe=[regex]::Replace($safe,'(?i)\b(Bearer|Basic)\s+[A-Za-z0-9+/=_\-.]+','$1 [REDACTED]')
    $secretNames='password|passwd|pwd|token|secret|api[_-]?key|client[_-]?secret|private[_-]?key|wallet|credential|authorization'
    $safe=[regex]::Replace($safe,'(?i)(["'']?(?:'+$secretNames+')["'']?\s*[=:]\s*)(?:"[^"]*"|''[^'']*''|[^\s,;<>]+)','$1[REDACTED]')
    $safe=[regex]::Replace($safe,'(?is)(<(?:'+$secretNames+')[^>]*>).*?(</(?:'+$secretNames+')\s*>)','$1[REDACTED]$2')
    $safe=[regex]::Replace($safe,'(?is)-----BEGIN [^-]*(PRIVATE KEY|CERTIFICATE)[^-]*-----.*?-----END [^-]*(PRIVATE KEY|CERTIFICATE)[^-]*-----','[REDACTED-KEY-MATERIAL]')
    $safe=[regex]::Replace($safe,'(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b','[REDACTED-IDENTIFIER]')
    $safe=[regex]::Replace($safe,'(?i)"((?:[A-Z]:\\|\\\\)[^"]+)"',{param($m)'['+(Get-WsmDeveloperProbeSafeAlias $m.Groups[1].Value 'path' $Salt)+']'})
    $safe=[regex]::Replace($safe,'(?i)\b(?:[A-Z]:\\|\\\\)[^\r\n,;"''<>|]+',{param($m)$path=$m.Value.TrimEnd('.',')',']','}');'['+(Get-WsmDeveloperProbeSafeAlias $path 'path' $Salt)+']'})
    $safe=[regex]::Replace($safe,'(?i)(\b(?:host|computer|machine|server)(?:name)?\s*[=:]\s*)([^\s,;]+)',{param($m)$m.Groups[1].Value+'['+(Get-WsmDeveloperProbeSafeAlias $m.Groups[2].Value 'host' $Salt)+']'})
    if($safe.Length -gt 512){$safe=$safe.Substring(0,512)+'…[TRUNCATED]'}
    $safe
}

function Get-WsmDeveloperProbeCancellationPath([string]$Workspace,[string]$OperationId) {
    $workspacePath=[IO.Path]::GetFullPath($Workspace);$driveRoot=[IO.Path]::GetPathRoot($workspacePath)
    if(-not [IO.Path]::IsPathRooted($Workspace) -or $workspacePath.StartsWith('\\') -or $driveRoot.StartsWith('\\')){throw 'Developer probe cancellation requires a local absolute workspace.'}
    $operationGuid=[Guid]::Empty;if(-not [Guid]::TryParse($OperationId,[ref]$operationGuid)){throw 'Developer probe cancellation operation id must be a GUID.'}
    Join-Path (Join-Path (Join-Path $workspacePath 'developer-probes') '.cancellations') ($operationGuid.ToString('D')+'.json')
}

function New-WsmDeveloperProbeCancellationToken([string]$Workspace,[string]$OperationId) {
    $path=Get-WsmDeveloperProbeCancellationPath $Workspace $OperationId;$folder=Split-Path $path -Parent
    $probeRoot=Split-Path $folder -Parent
    foreach($directory in @($probeRoot,$folder)){Assert-WsmNoReparse $directory;if(-not [IO.Directory]::Exists($directory)){[void][IO.Directory]::CreateDirectory($directory);Protect-WsmDirectory $directory}}
    [pscustomobject]@{Kind='DeveloperProbeCancellationToken';Workspace=[IO.Path]::GetFullPath($Workspace);OperationId=([Guid]$OperationId).ToString('D');RequestPath=$path}
}

function Request-WsmDeveloperProbeCancellation($CancellationToken) {
    if(-not $CancellationToken -or [string]$CancellationToken.Kind -cne 'DeveloperProbeCancellationToken'){throw 'A developer probe cancellation token is required.'}
    $expected=Get-WsmDeveloperProbeCancellationPath ([string]$CancellationToken.Workspace) ([string]$CancellationToken.OperationId)
    if([IO.Path]::GetFullPath([string]$CancellationToken.RequestPath) -ine [IO.Path]::GetFullPath($expected)){throw 'Developer probe cancellation token path does not match its operation id.'}
    $folder=Split-Path $expected -Parent;Assert-WsmNoReparse $folder
    if(-not [IO.Directory]::Exists($folder)){throw 'Developer probe cancellation directory does not exist.'}
    $marker=[pscustomobject]@{Kind='DeveloperProbeCancellationRequest';OperationId=([Guid]$CancellationToken.OperationId).ToString('D');RequestedUtc=[DateTime]::UtcNow.ToString('o')}
    $json=$marker|ConvertTo-Json -Compress;[IO.File]::WriteAllText($expected,$json,(New-Object Text.UTF8Encoding($false)));$marker
}

function Test-WsmDeveloperProbeCancellationRequested($CancellationToken,[string]$Workspace) {
    if(-not $CancellationToken){return $false}
    if([string]$CancellationToken.Kind -cne 'DeveloperProbeCancellationToken'){return [bool](Test-WsmCancellationRequested $CancellationToken)}
    $expected=Get-WsmDeveloperProbeCancellationPath $Workspace ([string]$CancellationToken.OperationId)
    if([IO.Path]::GetFullPath([string]$CancellationToken.Workspace) -ine [IO.Path]::GetFullPath($Workspace) -or [IO.Path]::GetFullPath([string]$CancellationToken.RequestPath) -ine [IO.Path]::GetFullPath($expected)){throw 'Developer probe cancellation token does not belong to this workspace operation.'}
    $folder=Split-Path $expected -Parent;Assert-WsmNoReparse $folder
    if(-not [IO.File]::Exists($expected)){return $false}
    $info=[IO.FileInfo]::new($expected);if($info.Length -gt 4096){throw 'Developer probe cancellation marker exceeds its size limit.'}
    $marker=[IO.File]::ReadAllText($expected)|ConvertFrom-Json
    if([string]$marker.Kind -cne 'DeveloperProbeCancellationRequest' -or [string]$marker.OperationId -cne ([Guid]$CancellationToken.OperationId).ToString('D')){throw 'Developer probe cancellation marker identity is invalid.'}
    $true
}

function ConvertTo-WsmDeveloperProbeRedactedShape($Value) {
    if($null -eq $Value){return [pscustomobject]@{Redacted=$true;OriginalType='Null'}}
    if($Value -is [string]){return '[REDACTED]'}
    if($Value -is [System.Collections.IDictionary]){$properties=@(foreach($key in @($Value.Keys|Select-Object -First 32)){[pscustomobject]@{Name=(ConvertTo-WsmDeveloperProbeSafeText ([string]$key) '');OriginalType=$(if($null -eq $Value[$key]){'Null'}else{$Value[$key].GetType().Name})}});return [pscustomobject]@{Redacted=$true;OriginalType='Dictionary';PropertyCount=$Value.Count;Properties=$properties}}
    if($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]){$elementTypes=New-Object System.Collections.Generic.List[string];$count=0;foreach($element in $Value){if($count -lt 32){$type=if($null -eq $element){'Null'}else{$element.GetType().Name};if(-not $elementTypes.Contains($type)){$elementTypes.Add($type)}};$count++};return [pscustomobject]@{Redacted=$true;OriginalType='Array';Count=$count;ElementTypes=@($elementTypes.ToArray())}}
    if($Value -is [ValueType]){return [pscustomobject]@{Redacted=$true;OriginalType=$Value.GetType().Name}}
    $props=@($Value.PSObject.Properties|Select-Object -First 32);$shape=@(foreach($property in $props){[pscustomobject]@{Name=(ConvertTo-WsmDeveloperProbeSafeText ([string]$property.Name) '');OriginalType=$(if($null -eq $property.Value){'Null'}else{$property.Value.GetType().Name})}})
    [pscustomobject]@{Redacted=$true;OriginalType=$Value.GetType().Name;PropertyCount=@($Value.PSObject.Properties).Count;Properties=$shape}
}

function ConvertTo-WsmDeveloperProbeSafeObject {
    param([AllowNull()]$InputObject,[int]$Depth=0,[string]$Salt='')
    if($null -eq $InputObject){return $null}
    if($Depth -gt 10){return '[DEPTH-LIMIT]'}
    if($InputObject -is [string]){return (ConvertTo-WsmDeveloperProbeSafeText $InputObject $Salt)}
    if($InputObject -is [ValueType]){return $InputObject}
    if($InputObject -is [System.Collections.IDictionary]){
        $result=[ordered]@{}
        foreach($key in $InputObject.Keys){$originalName=[string]$key;$value=$InputObject[$key];$name=ConvertTo-WsmDeveloperProbeSafeText $originalName $Salt;if($originalName -match '(?i)(?:[a-z0-9]{4,}[_-]){2,}[a-z0-9]{3,}'){$name='field-'+(Get-WsmDeveloperProbeSafeAlias $originalName 'field' $Salt)};$baseName=$name;$suffix=2;while($result.Contains($name)){$name=$baseName+'_'+$suffix;$suffix++};if($originalName -match '(?i)password|passwd|secret|token|private.?key|wallet|credential|arguments?|commandline|rawvalue|xml|script|connectionstring|authorization|user(name)?|accountname|subject|filename|headers?|thumbprint|sid|error(?!type|summary|id)|message|evidence'){ $result[$name]=ConvertTo-WsmDeveloperProbeRedactedShape $value }elseif($originalName -ceq 'ToolFingerprint' -and $value -is [string] -and $value -match '^[a-fA-F0-9]{64}$'){$result[$name]=$value.ToLowerInvariant()}elseif($originalName -match '(?i)fingerprint|machine.?guid|host.?id|machine.?id|path|directory|folder|host(name)?|computer(name)?|machine(name)?'){if($value -is [string]){$kind=if($originalName -match '(?i)fingerprint|machine.?guid|host.?id|machine.?id|host|computer|machine'){'host'}else{'path'};$result[$name]= '['+(Get-WsmDeveloperProbeSafeAlias ([string]$value) $kind $Salt)+']'}else{$result[$name]=ConvertTo-WsmDeveloperProbeSafeObject $value ($Depth+1) $Salt}}else{$result[$name]=ConvertTo-WsmDeveloperProbeSafeObject $value ($Depth+1) $Salt}}
        return [pscustomobject]$result
    }
    if($InputObject -is [System.Collections.IEnumerable]){
        $values=New-Object 'System.Collections.Generic.List[object]';$count=0
        foreach($value in $InputObject){if($count -ge 2000){$values.Add('[ITEM-LIMIT]');break};$values.Add((ConvertTo-WsmDeveloperProbeSafeObject $value ($Depth+1) $Salt));$count++}
        return ,@($values.ToArray())
    }
    if($InputObject.PSObject -and $InputObject.PSObject.Properties){
        $result=[ordered]@{}
        foreach($property in $InputObject.PSObject.Properties){$originalName=[string]$property.Name;$value=$property.Value;$name=ConvertTo-WsmDeveloperProbeSafeText $originalName $Salt;if($originalName -match '(?i)(?:[a-z0-9]{4,}[_-]){2,}[a-z0-9]{3,}'){$name='field-'+(Get-WsmDeveloperProbeSafeAlias $originalName 'field' $Salt)};$baseName=$name;$suffix=2;while($result.Contains($name)){$name=$baseName+'_'+$suffix;$suffix++};if($originalName -match '(?i)password|passwd|secret|token|private.?key|wallet|credential|arguments?|commandline|rawvalue|xml|script|connectionstring|authorization|user(name)?|accountname|subject|filename|headers?|thumbprint|sid|error(?!type|summary|id)|message|evidence'){ $result[$name]=ConvertTo-WsmDeveloperProbeRedactedShape $value }elseif($originalName -ceq 'ToolFingerprint' -and $value -is [string] -and $value -match '^[a-fA-F0-9]{64}$'){$result[$name]=$value.ToLowerInvariant()}elseif($originalName -match '(?i)fingerprint|machine.?guid|host.?id|machine.?id|path|directory|folder|host(name)?|computer(name)?|machine(name)?'){if($value -is [string]){$kind=if($originalName -match '(?i)fingerprint|machine.?guid|host.?id|machine.?id|host|computer|machine'){'host'}else{'path'};$result[$name]= '['+(Get-WsmDeveloperProbeSafeAlias ([string]$value) $kind $Salt)+']'}else{$result[$name]=ConvertTo-WsmDeveloperProbeSafeObject $value ($Depth+1) $Salt}}else{$result[$name]=ConvertTo-WsmDeveloperProbeSafeObject $value ($Depth+1) $Salt}}
        return [pscustomobject]$result
    }
    ConvertTo-WsmDeveloperProbeSafeText ([string]$InputObject) $Salt
}

function Get-WsmDeveloperProbeRawBytes([string]$Root) {
    if(-not [IO.Directory]::Exists($Root)){return [long]0}
    $total=[long]0;$pending=New-Object 'System.Collections.Generic.Stack[string]';$pending.Push($Root)
    while($pending.Count -gt 0){
        $directory=$pending.Pop()
        foreach($path in [IO.Directory]::EnumerateFileSystemEntries($directory)){
            $attributes=[IO.File]::GetAttributes($path)
            if(($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){continue}
            if(($attributes -band [IO.FileAttributes]::Directory) -ne 0){$pending.Push($path)}else{$total += [IO.FileInfo]::new($path).Length}
        }
    }
    $total
}

function Test-WsmDeveloperProbeSafeProcessModuleRoot([string]$Path){$result=[ordered]@{Allowed=$false;Path=$Path;ReasonCode='InvalidOrUnsupportedPath'};if([string]::IsNullOrWhiteSpace($Path) -or $Path -match '^(?:\\\\|//|\\\\\?\\|\\\\\.\\)'){return [pscustomobject]$result};try{$full=[IO.Path]::GetFullPath($Path)}catch{$result.ReasonCode='InvalidLocalPath';return [pscustomobject]$result};if($full -notmatch '^[A-Za-z]:\\'){$result.ReasonCode='UnsupportedLocalPathNamespace';return [pscustomobject]$result};$root=$full.Substring(0,3);try{$drive=New-Object IO.DriveInfo -ArgumentList $root;if($drive.DriveType -eq [IO.DriveType]::Network){$result.ReasonCode='MappedRemoteDriveBlocked';return [pscustomobject]$result}}catch{$result.ReasonCode='DriveTypeUnavailable';return [pscustomobject]$result};$current=$root;foreach($part in @($full.Substring(3).TrimEnd('\\') -split '[\\/]'|Where-Object {$_})){$current=Join-Path $current $part;try{if(([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0){$result.ReasonCode='ReparseAncestorBlocked';return [pscustomobject]$result}}catch [IO.FileNotFoundException]{return [pscustomobject]@{Allowed=$false;Path=$full;ReasonCode='PathDoesNotExist'}}catch [IO.DirectoryNotFoundException]{return [pscustomobject]@{Allowed=$false;Path=$full;ReasonCode='PathDoesNotExist'}}catch{$result.ReasonCode='PathInspectionFailed';return [pscustomobject]$result}};[pscustomobject]@{Allowed=$true;Path=$full;ReasonCode=''}}

function ConvertTo-WsmDeveloperProbeInventoryProjection($Inventory,[string]$InventoryHash,[string]$Salt,[object[]]$ScopeGaps=@(),[int]$InventoryIncompleteCount=-1) {
    $counts=@{};foreach($item in @($Inventory.Items)){$key=[string]$item.Category+'|'+[string]$item.Status;if(-not $counts.ContainsKey($key)){$counts[$key]=0};$counts[$key]++}
    $coverageGaps=New-Object System.Collections.Generic.List[object]
    foreach($item in @($Inventory.Items|Where-Object {$_.Status -in @('Partial','Failed','PermissionDenied','Unsupported','NotTested')})){$coverageGaps.Add([pscustomobject]@{Source='InventoryItem';ItemId=[string]$item.ItemId;Category=[string]$item.Category;Kind=[string]$item.Kind;Status=[string]$item.Status;ReasonCode=$(if($item.Settings -and $item.Settings.PSObject.Properties['ErrorKind']){[string]$item.Settings.ErrorKind}elseif($item.Settings -and $item.Settings.PSObject.Properties['ErrorType']){[string]$item.Settings.ErrorType}else{$null})})}
    foreach($row in @($Inventory.SoftwareCatalog.Coverage|Where-Object {$_.Status -in @('Partial','Failed','PermissionDenied','Unsupported','NotTested')})){$coverageGaps.Add([pscustomobject]@{Source='SoftwareCatalog';Probe=[string]$row.Probe;Scope=[string]$row.Scope;Status=[string]$row.Status;ReasonCode=$(if($row.PSObject.Properties['ErrorKind']){[string]$row.ErrorKind}else{$null});ItemId=$(if($row.PSObject.Properties['ItemId']){[string]$row.ItemId}else{''})})}
    foreach($row in @($Inventory.WorkloadDiscovery.Coverage|Where-Object {$_.Status -in @('Partial','Failed','PermissionDenied','Unsupported','NotTested')})){$coverageGaps.Add([pscustomobject]@{Source='WorkloadDiscovery';Probe=[string]$row.Probe;Scope=[string]$row.Scope;Status=[string]$row.Status;ReasonCode=$(if($row.PSObject.Properties['ReasonCode']){[string]$row.ReasonCode}else{$null});ItemId=$(if($row.PSObject.Properties['ItemId']){[string]$row.ItemId}else{''})})}
    foreach($gap in @($ScopeGaps)){$coverageGaps.Add([pscustomobject]@{Source='ProbeScopeGuard';Collector=[string]$gap.Collector;Operation=[string]$gap.Operation;Status='Partial';ReasonCode=[string]$gap.ReasonCode;ItemId=[string]$gap.ItemId})}
    $observedItemFailures=@($Inventory.Items|Where-Object {$_.Status -ne 'Success'}).Count
    if($InventoryIncompleteCount -lt 0){$InventoryIncompleteCount=$observedItemFailures}
    if($InventoryIncompleteCount -gt $coverageGaps.Count){$coverageGaps.Add([pscustomobject]@{Source='InventorySummary';Status='Partial';ReasonCode='InventoryIncompleteCount';Count=$InventoryIncompleteCount;UnmappedCount=($InventoryIncompleteCount-$coverageGaps.Count)})}
    $workloadSummary=@{Present=($null -ne $Inventory.WorkloadDiscovery);ReferenceCount=0;Categories=@()};$workloadData=$null
    if($Inventory.WorkloadDiscovery){$refs=@($Inventory.WorkloadDiscovery.References);$workloadSummary.ReferenceCount=$refs.Count;$workloadSummary.Categories=@($refs|ForEach-Object {[string]$_.ReferenceKind}|Sort-Object -Unique);$discovery=$Inventory.WorkloadDiscovery;$schemaVersion=if($discovery.PSObject.Properties['SchemaVersion']){$discovery.SchemaVersion}else{$null};$workloadData=[pscustomobject]@{SchemaVersion=$schemaVersion;Kind=[string]$discovery.Kind;References=@($discovery.References);SharedResources=@($discovery.SharedResources);RuntimeObservations=@($discovery.RuntimeObservations);ProducerProvenance=@($discovery.ProducerProvenance);ConfigurationCoverage=@($discovery.ConfigurationCoverage);Coverage=@($discovery.Coverage);Complete=$false;CompletenessReason=[string]$discovery.CompletenessReason}}
    $softwareSummary=@{Present=($null -ne $Inventory.SoftwareCatalog);ApplicationCount=0;Status='Unknown'};$softwareData=$null
    if($Inventory.SoftwareCatalog){$catalog=$Inventory.SoftwareCatalog;$softwareSummary.ApplicationCount=@($catalog.Entries).Count;$softwareSummary.Status=if($catalog.PSObject.Properties['Status']){[string]$catalog.Status}else{'Unknown'};$softwareData=[pscustomobject]@{SchemaVersion=$catalog.SchemaVersion;ToolVersion=[string]$catalog.ToolVersion;Kind=[string]$catalog.Kind;CaptureContext=$catalog.CaptureContext;Entries=@($catalog.Entries);Coverage=@($catalog.Coverage);PreparationRequirements=@($catalog.PreparationRequirements)}}
    $sourceData=ConvertTo-WsmDeveloperProbeSafeObject $Inventory.Source 0 $Salt
    if($Inventory.Source.Name){$sourceName=[string]$Inventory.Source.Name;if($sourceName -notmatch '^\[host-[a-f0-9]{12}\]$'){$sourceName='['+(Get-WsmDeveloperProbeSafeAlias $sourceName 'host' $Salt)+']'};$sourceData|Add-Member -MemberType NoteProperty -Name Name -Value $sourceName -Force}
    [pscustomobject]@{Status=$(if($InventoryIncompleteCount -gt 0 -or $coverageGaps.Count){'Partial'}else{'Completed'});ReasonCode=$(if($ScopeGaps.Count){'UnsafeScopeSkipped'}elseif($InventoryIncompleteCount -gt 0 -or $coverageGaps.Count){'InventoryCoverageIncomplete'}else{$null});Depth=[string]$Inventory.Source.DiscoveryDepth;Source=$sourceData;ToolVersion=[string]$Inventory.ToolVersion;ToolFingerprint=$Inventory.ToolFingerprint;InventorySHA256=$InventoryHash;ItemCount=@($Inventory.Items).Count;Items=@($Inventory.Items);CategoryStatusCounts=$counts;ItemFailures=$observedItemFailures;IncompleteCount=$InventoryIncompleteCount;CoverageGapCount=$coverageGaps.Count;CoverageGaps=$coverageGaps.ToArray();ScopeGaps=@($ScopeGaps);Workload=$workloadSummary;WorkloadDiscovery=$workloadData;Software=$softwareSummary;SoftwareCatalog=$softwareData;RawEvidence='ProtectedLocalOnly'}
}

function Install-WsmDeveloperProbeInventoryGuards {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Module,[string]$Salt)
    & $Module {
        param($ProbeSalt)
        $script:WsmDeveloperProbeScopeGaps=New-Object 'System.Collections.Generic.List[object]'
        function script:Test-WsmDeveloperProbeSafeLocalPath([string]$Path) {
            $result=[ordered]@{Allowed=$false;ReasonCode='InvalidOrUnsupportedPath';Path=$Path;ReparseAncestor=$null}
            if([string]::IsNullOrWhiteSpace($Path)){return [pscustomobject]$result}
            $candidate=$Path.Trim()
            if($candidate -match '^(?:\\\\|//|\\\\\?\\|\\\\\.\\)'){$result.ReasonCode='RemoteOrDevicePathBlocked';return [pscustomobject]$result}
            if($candidate -match '^[A-Za-z]:[^\\/]'){$result.ReasonCode='DriveRelativePathBlocked';return [pscustomobject]$result}
            try{$full=[IO.Path]::GetFullPath($candidate)}catch{$result.ReasonCode='InvalidLocalPath';return [pscustomobject]$result}
            if($full -notmatch '^[A-Za-z]:\\'){$result.ReasonCode='UnsupportedLocalPathNamespace';return [pscustomobject]$result}
            $root=$full.Substring(0,3)
            try{$drive=New-Object IO.DriveInfo -ArgumentList $root;if($drive.DriveType -eq [IO.DriveType]::Network){$result.ReasonCode='MappedRemoteDriveBlocked';return [pscustomobject]$result}}catch{$result.ReasonCode='DriveTypeUnavailable';return [pscustomobject]$result}
            $relative=$full.Substring(3).TrimEnd('\\');$current=$root
            foreach($part in @($relative -split '[\\/]' | Where-Object {$_})) {
                $current=Join-Path $current $part
                try{$attributes=[IO.File]::GetAttributes($current);if(($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){$result.ReasonCode='ReparseAncestorBlocked';$result.ReparseAncestor=$current;return [pscustomobject]$result}}catch [System.IO.FileNotFoundException] { return [pscustomobject]@{Allowed=$true;ReasonCode='';Path=$full;ReparseAncestor=$null} }catch [System.IO.DirectoryNotFoundException] { return [pscustomobject]@{Allowed=$true;ReasonCode='';Path=$full;ReparseAncestor=$null} }catch [System.UnauthorizedAccessException] {$result.ReasonCode='PathAttributesDenied';return [pscustomobject]$result}catch {$result.ReasonCode='PathInspectionFailed';return [pscustomobject]$result}
            }
            [pscustomobject]@{Allowed=$true;ReasonCode='';Path=$full;ReparseAncestor=$null}
        }
        function script:Add-WsmDeveloperProbeScopeGap([string]$Collector,[string]$Operation,[string]$ReasonCode,[string]$Path,[string]$ItemId,[string]$Ancestor) {
            $script:WsmDeveloperProbeScopeGaps.Add([pscustomobject][ordered]@{Collector=$Collector;Operation=$Operation;ReasonCode=$ReasonCode;Path=$Path;ItemId=$ItemId;ReparseAncestor=$Ancestor;Action='SkippedBeforeEnumerationOrRead'})
        }
        function script:Get-WsmDeveloperProbeSafeModuleSnapshot([int]$MaxEntries=2000) {
            $rows=New-Object System.Collections.Generic.List[object];$incomplete=$false
            $addManifest={param([string]$ManifestPath,[string]$ModuleBase,[string]$FallbackName)
                if($rows.Count -ge $MaxEntries){$script:WsmDeveloperProbeScopeGaps.Add([pscustomobject]@{Collector='NativeInventory';Operation='ModuleDiscovery';ReasonCode='EntryBudgetExceeded';Path=$ManifestPath;ItemId='';ReparseAncestor=$null;Action='SkippedBeforeEnumerationOrRead'});$incomplete=$true;return}
                $safe=Test-WsmDeveloperProbeSafeLocalPath $ManifestPath;if(-not $safe.Allowed){$script:WsmDeveloperProbeScopeGaps.Add([pscustomobject]@{Collector='NativeInventory';Operation='ModuleDiscovery';ReasonCode=$safe.ReasonCode;Path=$ManifestPath;ItemId='';ReparseAncestor=$safe.ReparseAncestor;Action='SkippedBeforeEnumerationOrRead'});$incomplete=$true;return}
                try{$data=Import-PowerShellDataFile -LiteralPath $safe.Path -ErrorAction Stop;$name=[string]$data.RootModule;if(-not $name){$name=[string]$data.ModuleToProcess};if(-not $name){$name=$FallbackName};$exportNames=@();foreach($key in @('FunctionsToExport','CmdletsToExport','AliasesToExport')){if($data.Contains($key)){$exportNames+=@($data[$key]|ForEach-Object {[string]$_})}};$version=if($data.ModuleVersion){[string]$data.ModuleVersion}else{'Unknown'};$rows.Add([pscustomobject]@{Name=$FallbackName;Version=$version;ModuleBase=$ModuleBase;Path=$safe.Path;ManifestPath=$safe.Path;ExportedCommandNames=$exportNames})}catch{$script:WsmDeveloperProbeScopeGaps.Add([pscustomobject]@{Collector='NativeInventory';Operation='ModuleDiscovery';ReasonCode='ManifestReadFailed';Path=$ManifestPath;ItemId='';ReparseAncestor=$null;Action='SkippedBeforeEnumerationOrRead'});$incomplete=$true}
            }
            foreach($moduleRoot in @($env:PSModulePath -split [regex]::Escape([IO.Path]::PathSeparator))){
                if(-not $moduleRoot){continue};$rootSafe=Test-WsmDeveloperProbeSafeLocalPath $moduleRoot
                if(-not $rootSafe.Allowed){$script:WsmDeveloperProbeScopeGaps.Add([pscustomobject]@{Collector='NativeInventory';Operation='ModuleDiscovery';ReasonCode=$rootSafe.ReasonCode;Path=$moduleRoot;ItemId='';ReparseAncestor=$rootSafe.ReparseAncestor;Action='SkippedBeforeEnumerationOrRead'});$incomplete=$true;continue}
                if(-not [IO.Directory]::Exists($rootSafe.Path)){continue}
                try{
                    foreach($moduleDirectory in [IO.Directory]::EnumerateDirectories($rootSafe.Path)){
                        $dirSafe=Test-WsmDeveloperProbeSafeLocalPath $moduleDirectory;if(-not $dirSafe.Allowed){$script:WsmDeveloperProbeScopeGaps.Add([pscustomobject]@{Collector='NativeInventory';Operation='ModuleDiscovery';ReasonCode=$dirSafe.ReasonCode;Path=$moduleDirectory;ItemId='';ReparseAncestor=$dirSafe.ReparseAncestor;Action='SkippedBeforeEnumerationOrRead'});$incomplete=$true;continue}
                        $moduleName=[IO.Path]::GetFileName($moduleDirectory)
                        foreach($manifest in [IO.Directory]::EnumerateFiles($dirSafe.Path,'*.psd1')){& $addManifest $manifest $dirSafe.Path $moduleName}
                        foreach($versionDirectory in [IO.Directory]::EnumerateDirectories($dirSafe.Path)){
                            $versionSafe=Test-WsmDeveloperProbeSafeLocalPath $versionDirectory;if(-not $versionSafe.Allowed){$script:WsmDeveloperProbeScopeGaps.Add([pscustomobject]@{Collector='NativeInventory';Operation='ModuleDiscovery';ReasonCode=$versionSafe.ReasonCode;Path=$versionDirectory;ItemId='';ReparseAncestor=$versionSafe.ReparseAncestor;Action='SkippedBeforeEnumerationOrRead'});$incomplete=$true;continue}
                            foreach($manifest in [IO.Directory]::EnumerateFiles($versionSafe.Path,'*.psd1')){& $addManifest $manifest $versionSafe.Path $moduleName}
                        }
                    }
                    foreach($manifest in [IO.Directory]::EnumerateFiles($rootSafe.Path,'*.psd1')){& $addManifest $manifest $rootSafe.Path ([IO.Path]::GetFileNameWithoutExtension($manifest))}
                }catch{$script:WsmDeveloperProbeScopeGaps.Add([pscustomobject]@{Collector='NativeInventory';Operation='ModuleDiscovery';ReasonCode='LocalModuleEnumerationFailed';Path=$rootSafe.Path;ItemId='';ReparseAncestor=$null;Action='SkippedBeforeEnumerationOrRead'});$incomplete=$true}
            }
            $unique=@{};foreach($row in $rows){$key=([string]$row.Name+'|'+[string]$row.Version+'|'+[string]$row.ManifestPath).ToLowerInvariant();if(-not $unique.ContainsKey($key)){$unique[$key]=$row}}
            $ordered=@($unique.Values|Sort-Object Name,Version -Descending|Select-Object -First $MaxEntries)
            $moduleGaps=@($script:WsmDeveloperProbeScopeGaps|Where-Object Operation -EQ 'ModuleDiscovery')
            [pscustomobject]@{Status=$(if($moduleGaps.Count){'Partial'}else{'Success'});Rows=$ordered;ErrorKind=$(if($moduleGaps.Count){'LocalOnlyModuleDiscoveryIncomplete'}else{$null});Count=$ordered.Count;Budget=[pscustomobject]@{MaxEntries=$MaxEntries;SearchRoots='LocalNonReparseOnly'}}
        }
        Set-Item Function:\script:Test-Path -Value {
            [CmdletBinding(DefaultParameterSetName='Path')]
            param(
                [Parameter(ParameterSetName='Path',Position=0,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)][Alias('PSPath')][string[]]$Path,
                [Parameter(ParameterSetName='LiteralPath',Mandatory=$true,ValueFromPipelineByPropertyName=$true)][Alias('LP')][string[]]$LiteralPath,
                [ValidateSet('Any','Container','Leaf')][string]$PathType='Any',[switch]$IsValid,[string]$Filter,[string[]]$Include,[string[]]$Exclude,[pscredential]$Credential,[switch]$UseTransaction
            )
            process {
                $paths=if($PSCmdlet.ParameterSetName -eq 'LiteralPath'){@($LiteralPath)}else{@($Path)}
                foreach($candidate in $paths){
                    if($IsValid){Microsoft.PowerShell.Management\Test-Path -LiteralPath $candidate -IsValid;continue}
                    if($candidate -match '^(?:\\\\|//|[A-Za-z]:\\|[A-Za-z]:/)'){
                        $check=Test-WsmDeveloperProbeSafeLocalPath $candidate
                        if(-not $check.Allowed){Add-WsmDeveloperProbeScopeGap 'NativeInventory' 'FilesystemPathProbe' $check.ReasonCode $candidate '' $check.ReparseAncestor;$false;continue}
                    }
                    $args=@{LiteralPath=$candidate;PathType=$PathType;ErrorAction='SilentlyContinue'};if($Filter){$args.Filter=$Filter};if($Include){$args.Include=$Include};if($Exclude){$args.Exclude=$Exclude};if($Credential){$args.Credential=$Credential};if($UseTransaction){$args.UseTransaction=$true}
                    Microsoft.PowerShell.Management\Test-Path @args
                }
            }
        }
        $moduleSnapshot=Get-Command Get-WsmSoftwareModuleSnapshot -CommandType Function -ErrorAction SilentlyContinue
        if($moduleSnapshot){$script:WsmDeveloperProbeOriginalModuleSnapshot=$moduleSnapshot.ScriptBlock
            Set-Item Function:\script:Get-WsmSoftwareModuleSnapshot -Value {param([int]$MaxEntries=2000);Get-WsmDeveloperProbeSafeModuleSnapshot $MaxEntries}
        }
        $fileMetadata=Get-Command Get-WsmSoftwareFileMetadataSnapshot -CommandType Function -ErrorAction SilentlyContinue
        if($fileMetadata){$script:WsmDeveloperProbeOriginalFileMetadata=$fileMetadata.ScriptBlock
            Set-Item Function:\script:Get-WsmSoftwareFileMetadataSnapshot -Value {
                param([Parameter(Mandatory)][string]$Path)
                $check=Test-WsmDeveloperProbeSafeLocalPath $Path
                if(-not $check.Allowed){Add-WsmDeveloperProbeScopeGap 'SoftwareCatalog' 'ConsumerFileMetadata' $check.ReasonCode $Path '' $check.ReparseAncestor;return [pscustomobject]@{Status='Partial';Row=$null;ErrorKind=$check.ReasonCode;ProbeScopeGap=$true}}
                & $script:WsmDeveloperProbeOriginalFileMetadata -Path $Path
            }
        }
        $adjacent=Get-Command Get-WsmSoftwareAdjacentRuntimeSnapshot -CommandType Function -ErrorAction SilentlyContinue
        if($adjacent){$script:WsmDeveloperProbeOriginalAdjacentRuntime=$adjacent.ScriptBlock
            Set-Item Function:\script:Get-WsmSoftwareAdjacentRuntimeSnapshot -Value {
                param([Parameter(Mandatory)][string]$ExecutablePath,[int]$MaxEntries=200,[long]$MaxMetadataBytes=1048576)
                $check=Test-WsmDeveloperProbeSafeLocalPath $ExecutablePath
                if(-not $check.Allowed){Add-WsmDeveloperProbeScopeGap 'SoftwareCatalog' 'AdjacentRuntimeMetadata' $check.ReasonCode $ExecutablePath '' $check.ReparseAncestor;$gap=[pscustomobject]@{Status='Partial';ErrorKind=$check.ReasonCode;Path=$ExecutablePath};return [pscustomobject]@{Status='Partial';Rows=@();Gaps=@($gap);Count=0;MetadataBytes=0}}
                & $script:WsmDeveloperProbeOriginalAdjacentRuntime -ExecutablePath $ExecutablePath -MaxEntries $MaxEntries -MaxMetadataBytes $MaxMetadataBytes
            }
        }
        $configSource=Get-Command Get-WsmIisConfigSourceEvidence -CommandType Function -ErrorAction SilentlyContinue
        if($configSource){$script:WsmDeveloperProbeOriginalConfigSource=$configSource.ScriptBlock
            Set-Item Function:\script:Get-WsmIisConfigSourceEvidence -Value {
                param($Node,[string]$ConfigurationPath)
                if(-not $Node.Attributes['configSource']){return & $script:WsmDeveloperProbeOriginalConfigSource $Node $ConfigurationPath}
                $relative=[string]$Node.GetAttribute('configSource');$base=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ConfigurationPath));$resolved=Join-Path $base $relative
                $check=Test-WsmDeveloperProbeSafeLocalPath $resolved
                if(-not $check.Allowed){Add-WsmDeveloperProbeScopeGap 'NativeInventory' 'IISConfigSourceRead' $check.ReasonCode $resolved '' $check.ReparseAncestor;return [pscustomobject][ordered]@{Status='ManualReviewRequired';RelativePath=$relative;ResolvedPath=$resolved;SHA256='';ProtectedXml='';Reason=$check.ReasonCode;ErrorKind=$check.ReasonCode}}
                & $script:WsmDeveloperProbeOriginalConfigSource $Node $ConfigurationPath
            }
        }
        $hosts=Get-Command Get-WsmHostsText -CommandType Function -ErrorAction SilentlyContinue
        if($hosts){$script:WsmDeveloperProbeOriginalHostsText=$hosts.ScriptBlock
            Set-Item Function:\script:Get-WsmHostsText -Value {
                $path=Join-Path $env:windir 'System32\drivers\etc\hosts';$check=Test-WsmDeveloperProbeSafeLocalPath $path
                if(-not $check.Allowed){Add-WsmDeveloperProbeScopeGap 'NativeInventory' 'HostsFileRead' $check.ReasonCode $path '' $check.ReparseAncestor;return $null}
                & $script:WsmDeveloperProbeOriginalHostsText
            }
        }
        $redirection=Get-Command Get-WsmIisRedirectionText -CommandType Function -ErrorAction SilentlyContinue
        if($redirection){$script:WsmDeveloperProbeOriginalIisRedirectionText=$redirection.ScriptBlock
            Set-Item Function:\script:Get-WsmIisRedirectionText -Value {
                $path=Join-Path $env:windir 'System32\inetsrv\config\redirection.config';$check=Test-WsmDeveloperProbeSafeLocalPath $path
                if(-not $check.Allowed){Add-WsmDeveloperProbeScopeGap 'NativeInventory' 'IisRedirectionConfigRead' $check.ReasonCode $path '' $check.ReparseAncestor;return $null}
                & $script:WsmDeveloperProbeOriginalIisRedirectionText
            }
        }
        $iis=Get-Command Get-WsmIisWebConfigInventoryItems -CommandType Function -ErrorAction SilentlyContinue
        if($iis){$script:WsmDeveloperProbeOriginalIisWebConfig=$iis.ScriptBlock
            Set-Item Function:\script:Get-WsmIisWebConfigInventoryItems -Value {
                param([string]$HostId,[object[]]$SiteItems,[int]$MaxDirectories=4096,[int]$MaxFiles=8192,[long]$MaxBytes=67108864,[int]$MaxFileBytes=4194304)
                $safeSites=New-Object System.Collections.Generic.List[object]
                $gapItems=New-Object System.Collections.Generic.List[object]
                foreach($site in @($SiteItems)){
                    try{$xml=Read-WsmXml ([string]$site.Settings.Xml)}catch{$safeSites.Add($site);continue}
                    $blocked=$false
                    foreach($node in @($xml.SelectNodes("//*[local-name()='virtualDirectory'][@physicalPath]"))){
                        $raw=[string]$node.GetAttribute('physicalPath');$expanded=[Environment]::ExpandEnvironmentVariables($raw)
                        $check=Test-WsmDeveloperProbeSafeLocalPath $expanded
                        if(-not $check.Allowed){$blocked=$true;Add-WsmDeveloperProbeScopeGap 'NativeInventory' 'IISWebConfigEnumeration' $check.ReasonCode $raw ([string]$site.ItemId) $check.ReparseAncestor;[void]$node.ParentNode.RemoveChild($node);continue}
                    }
                    if($blocked){$clone=[pscustomobject]@{ItemId=[string]$site.ItemId;NaturalKey=[string]$site.NaturalKey;Settings=[pscustomobject]@{Xml=$xml.OuterXml}};$safeSites.Add($clone)}else{$safeSites.Add($site)}
                }
                $localItems=@(& $script:WsmDeveloperProbeOriginalIisWebConfig $HostId $safeSites.ToArray() $MaxDirectories $MaxFiles $MaxBytes $MaxFileBytes)
                foreach($gap in @($script:WsmDeveloperProbeScopeGaps | Where-Object {$_.Collector -eq 'NativeInventory' -and $_.Operation -eq 'IISWebConfigEnumeration'})){
                    $gapItems.Add((New-WsmItem $HostId Web IISWebConfigObservation 'IIS web.config scope skipped by developer probe safety boundary' ('developer-probe-scope-gap|iis|'+[string]$gap.ItemId+'|'+[string]$gap.ReasonCode) ([pscustomobject][ordered]@{Status='SkippedUnsafeScope';ErrorKind=[string]$gap.ReasonCode;Path=[string]$gap.Path;ReparseAncestor=[string]$gap.ReparseAncestor;PotentialConsumerItemIds=@([string]$gap.ItemId);Reason='Developer probe did not enumerate remote, device or reparse paths.';RawEvidenceProtected=$true}) @() Partial))
                }
                @($localItems)+@($gapItems.ToArray())
            }
        }
        foreach($dfsCommand in @('Get-DfsnRoot')){
            Set-Item -Path ('Function:\script:'+ $dfsCommand) -Value ([scriptblock]::Create("param([string]`$Path,[Parameter(ValueFromRemainingArguments=`$true)]`$Remaining) Add-WsmDeveloperProbeScopeGap 'NativeInventory' 'EnterpriseDFS' 'RemoteOrDevicePathBlocked' ([string]`$Path) '' ''; throw 'Developer probe blocked automatic remote DFS enumeration.'"))
        }
    } $Salt
}

function Get-WsmDeveloperProbeInventoryScopeGaps($Module) {
    @(& $Module { @($script:WsmDeveloperProbeScopeGaps.ToArray()) })
}

function New-WsmDeveloperProbeWorker {
    param([string]$ModulePath,[string]$CollectorId,[string]$Role,[string]$Origin,[string]$RawRoot,[string]$Salt,[scriptblock]$Adapter)
    $state=[System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $runspace=[RunspaceFactory]::CreateRunspace($state);$runspace.Open()
    $powershell=[PowerShell]::Create();$powershell.Runspace=$runspace
    $script=@'
param($ModulePath,$CollectorId,$Role,$Origin,$RawRoot,$Salt,$AdapterText,$AutoLoadPreference,$OriginalModulePath)
$ErrorActionPreference='Stop'
$global:PSModuleAutoLoadingPreference=$AutoLoadPreference
$script:WsmDeveloperProbeWorkerStage='WorkerStartup'
trap { throw ('Developer probe worker failed during '+$script:WsmDeveloperProbeWorkerStage+': '+$_.Exception.Message) }
if($AdapterText){ $collectorAdapter=[scriptblock]::Create($AdapterText);return (& $collectorAdapter $CollectorId ([pscustomobject]@{Role=$Role;Origin=$Origin;RawRoot=$RawRoot})) }
function Get-WorkerAlias([string]$Value,[string]$Prefix){$hash=[Security.Cryptography.SHA256]::Create();try{$digest=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Salt+'|'+$Value.ToLowerInvariant()))).Replace('-','').ToLowerInvariant())}finally{$hash.Dispose()};$Prefix+'-'+$digest.Substring(0,12)}
function Get-WorkerManifestData([string]$ManifestPath){$manifestInfo=New-Object IO.FileInfo($ManifestPath);if(-not $manifestInfo.Exists){throw 'ManifestDoesNotExist'};if($manifestInfo.Length -gt 1048576){throw 'ManifestSizeBudgetExceeded'};$text=[IO.File]::ReadAllText($ManifestPath);$version='Unknown';$versionMatch=[regex]::Match($text,'(?im)^\s*ModuleVersion\s*=\s*[^0-9]*([0-9]+(?:\.[0-9]+){1,3})');if($versionMatch.Success){$version=$versionMatch.Groups[1].Value};$moduleName=[IO.Path]::GetFileName([IO.Path]::GetDirectoryName($ManifestPath));$root='';$rootMatch=[regex]::Match($text,'(?im)^\s*(?:RootModule|ModuleToProcess)\s*=\s*[^A-Za-z0-9_.-]*([A-Za-z0-9_.-]+\.psm1)');if($rootMatch.Success){$root=$rootMatch.Groups[1].Value};$exports=New-Object System.Collections.Generic.List[string];foreach($key in @('FunctionsToExport','CmdletsToExport','AliasesToExport')){$match=[regex]::Match($text,"(?is)\b$key\s*=\s*(?:@\s*\((?<array>[^)]*)\)|(?<scalar>[^,\r\n]+))");if($match.Success){$value=if($match.Groups['array'].Success){$match.Groups['array'].Value}else{$match.Groups['scalar'].Value};foreach($entry in [regex]::Matches($value,'[A-Za-z0-9_*?-]+')){if($entry.Value -and $entry.Value -notin @('FunctionsToExport','CmdletsToExport','AliasesToExport')){$exports.Add($entry.Value)}}}};[pscustomobject]@{Name=$moduleName;Version=$version;RootModule=$root;ExportedCommandNames=@($exports.ToArray())}}
function Get-WorkerLocalModuleSnapshot([int]$MaxEntries=2000){$rows=New-Object System.Collections.Generic.List[object];$gaps=New-Object System.Collections.Generic.List[object];$maxDirectories=[Math]::Max(100,[Math]::Min(4000,$MaxEntries*2));$maxManifests=[Math]::Max(100,[Math]::Min(8000,$MaxEntries*4));$maxGaps=500;$maxManifestBytes=1048576;$script:WsmWorkerDirectoriesVisited=0;$script:WsmWorkerManifestsVisited=0;$addGap={param([string]$path,[string]$reason)if($gaps.Count -lt $maxGaps){$gaps.Add([pscustomobject]@{Path=$path;ReasonCode=$reason})}};$add={param([string]$manifest,[string]$base,[string]$fallback);if($script:WsmWorkerManifestsVisited -ge $maxManifests){return};$script:WsmWorkerManifestsVisited++;try{$safe=Get-WorkerSafeLocalPath $manifest;if(-not $safe.Allowed){& $addGap $manifest $safe.ReasonCode;return};$info=New-Object IO.FileInfo($safe.Path);if(-not $info.Exists){return};if($info.Length -gt $maxManifestBytes){& $addGap $manifest 'ManifestSizeBudgetExceeded';return};$data=Get-WorkerManifestData $safe.Path;$exports=@($data.ExportedCommandNames|Select-Object -First 256);$rows.Add([pscustomobject]@{Name=$fallback;Version=[string]$data.Version;Path=$safe.Path;ModuleBase=$base;RootModule=[string]$data.RootModule;ExportedCommandNames=$exports})}catch{& $addGap $manifest 'ManifestReadFailed'}};foreach($root in @($env:PSModulePath -split [regex]::Escape([IO.Path]::PathSeparator))){if(-not $root){continue};$safeRoot=Get-WorkerSafeLocalPath $root;if(-not $safeRoot.Allowed){& $addGap $root $safeRoot.ReasonCode;continue};if(-not [IO.Directory]::Exists($safeRoot.Path)){continue};try{foreach($dir in [IO.Directory]::EnumerateDirectories($safeRoot.Path)){if($script:WsmWorkerDirectoriesVisited -ge $maxDirectories){& $addGap $safeRoot.Path 'ModuleDirectoryCountBudgetExceeded';break};$script:WsmWorkerDirectoriesVisited++;$safeDir=Get-WorkerSafeLocalPath $dir;if(-not $safeDir.Allowed){& $addGap $dir $safeDir.ReasonCode;continue};$name=[IO.Path]::GetFileName($dir);foreach($m in [IO.Directory]::EnumerateFiles($safeDir.Path,'*.psd1')){if($script:WsmWorkerManifestsVisited -ge $maxManifests){& $addGap $safeDir.Path 'ModuleManifestCountBudgetExceeded';break};& $add $m $safeDir.Path $name};if($script:WsmWorkerManifestsVisited -ge $maxManifests){break};foreach($versionDir in [IO.Directory]::EnumerateDirectories($safeDir.Path)){if($script:WsmWorkerDirectoriesVisited -ge $maxDirectories){& $addGap $safeDir.Path 'ModuleDirectoryCountBudgetExceeded';break};$script:WsmWorkerDirectoriesVisited++;$safeVersion=Get-WorkerSafeLocalPath $versionDir;if(-not $safeVersion.Allowed){& $addGap $versionDir $safeVersion.ReasonCode;continue};foreach($m in [IO.Directory]::EnumerateFiles($safeVersion.Path,'*.psd1')){if($script:WsmWorkerManifestsVisited -ge $maxManifests){& $addGap $safeVersion.Path 'ModuleManifestCountBudgetExceeded';break};& $add $m $safeVersion.Path $name};if($script:WsmWorkerManifestsVisited -ge $maxManifests){break}};if($script:WsmWorkerManifestsVisited -ge $maxManifests){break}};foreach($m in [IO.Directory]::EnumerateFiles($safeRoot.Path,'*.psd1')){if($script:WsmWorkerManifestsVisited -ge $maxManifests){& $addGap $safeRoot.Path 'ModuleManifestCountBudgetExceeded';break};& $add $m $safeRoot.Path ([IO.Path]::GetFileNameWithoutExtension($m))}}catch{& $addGap $safeRoot.Path 'LocalModuleEnumerationFailed'}};$unique=@{};$entryBudgetExceeded=$false;foreach($row in $rows){$key=([string]$row.Name+'|'+[string]$row.Version+'|'+[string]$row.Path).ToLowerInvariant();if($unique.ContainsKey($key)){continue};if($unique.Count -ge $MaxEntries){$entryBudgetExceeded=$true;continue};$unique[$key]=$row};if($entryBudgetExceeded){& $addGap '' 'ModuleEntryCountBudgetExceeded'};[pscustomobject]@{Rows=@($unique.Values|Sort-Object Name,Version -Descending);Gaps=@($gaps.ToArray());Status=$(if($gaps.Count -or $entryBudgetExceeded -or $script:WsmWorkerManifestsVisited -ge $maxManifests -or $script:WsmWorkerDirectoriesVisited -ge $maxDirectories){'Partial'}else{'Completed'});DirectoriesVisited=$script:WsmWorkerDirectoriesVisited;ManifestsVisited=$script:WsmWorkerManifestsVisited;EntryBudgetExceeded=$entryBudgetExceeded;EntryBudget=$MaxEntries}}
function Get-WorkerSafeLocalPath([string]$Path){$result=[ordered]@{Allowed=$false;ReasonCode='InvalidOrUnsupportedPath';Path=$Path};if([string]::IsNullOrWhiteSpace($Path)){return [pscustomobject]$result};if($Path -match '^(?:\\\\|//|\\\\\?\\|\\\\\.\\)'){$result.ReasonCode='RemoteOrDevicePathBlocked';return [pscustomobject]$result};if($Path -match '^[A-Za-z]:[^\\/]'){$result.ReasonCode='DriveRelativePathBlocked';return [pscustomobject]$result};try{$full=[IO.Path]::GetFullPath($Path)}catch{$result.ReasonCode='InvalidLocalPath';return [pscustomobject]$result};if($full -notmatch '^[A-Za-z]:\\'){$result.ReasonCode='UnsupportedLocalPathNamespace';return [pscustomobject]$result};$root=$full.Substring(0,3);try{$drive=New-Object IO.DriveInfo -ArgumentList $root;if($drive.DriveType -eq [IO.DriveType]::Network){$result.ReasonCode='MappedRemoteDriveBlocked';return [pscustomobject]$result}}catch{$result.ReasonCode='DriveTypeUnavailable';return [pscustomobject]$result};$current=$root;foreach($part in @($full.Substring(3).TrimEnd('\\') -split '[\\/]'|Where-Object {$_})){$current=Join-Path $current $part;try{if(([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0){$result.ReasonCode='ReparseAncestorBlocked';$result.Path=$full;$result.ReparseAncestor=$current;return [pscustomobject]$result}}catch [IO.FileNotFoundException] {return [pscustomobject]@{Allowed=$true;ReasonCode='';Path=$full}}catch [IO.DirectoryNotFoundException] {return [pscustomobject]@{Allowed=$true;ReasonCode='';Path=$full}}catch{$result.ReasonCode='PathInspectionFailed';return [pscustomobject]$result}};[pscustomobject]@{Allowed=$true;ReasonCode='';Path=$full}}
function Import-WorkerSafeCapabilityModules($Snapshot,[string[]]$Names=@('CimCmdlets','ScheduledTasks','WebAdministration','SmbShare','ServerManager','NetSecurity','DFSN','DFSR','NFS','MSMQ','DnsServer','DhcpServer','AppLocker')){$gaps=New-Object System.Collections.Generic.List[object];$allowed=$Names;$trustedRoots=@();if($env:windir){$trustedRoots+=Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\Modules'};if($PSHOME){$trustedRoots+=Join-Path $PSHOME 'Modules';$trustedRoots+=$PSHOME};$trustedRoots=@($trustedRoots|ForEach-Object {[IO.Path]::GetFullPath($_).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar});foreach($name in $allowed){$candidates=@($Snapshot.Rows|Where-Object Name -CEQ $name|Sort-Object {try{[version]$_.Version}catch{[version]'0.0'}} -Descending);foreach($candidate in $candidates){$manifest=[string]$candidate.Path;$base=[IO.Path]::GetFullPath([string]$candidate.ModuleBase);if(-not @($trustedRoots|Where-Object {$base.StartsWith($_,[StringComparison]::OrdinalIgnoreCase)}).Count){continue};$safe=Get-WorkerSafeLocalPath $manifest;if(-not $safe.Allowed){$gaps.Add([pscustomobject]@{Collector='NativeInventory';Operation='CapabilityModuleImport';ReasonCode=$safe.ReasonCode;Path=$manifest;ItemId=$name;Action='SkippedBeforeImport'});break};try{$manifestInfo=New-Object IO.FileInfo($safe.Path);if(-not $manifestInfo.Exists){throw 'ManifestDoesNotExist'};if($manifestInfo.Length -gt 1048576){throw 'ManifestSizeBudgetExceeded'};$manifestText=[IO.File]::ReadAllText($safe.Path);if($name -ceq 'CimCmdlets'){Import-Module -Name $safe.Path -Force -ErrorAction Stop;break};if($manifestText -match '(?im)^\s*RequiredModules\s*='){throw 'DependencyResolutionNotGuarded'};$rootMatch=[regex]::Match($manifestText,'(?im)^\s*(?:RootModule|ModuleToProcess)\s*=\s*[''\"]?(?<file>[^,''\"\r\n]+)');if($rootMatch.Success){$rootName=$rootMatch.Groups['file'].Value.Trim();if($rootName -match '^(?:\\\\|//|[A-Za-z]:)'){throw 'AbsoluteRootModuleBlocked'};$rootPath=Join-Path $base $rootName;$rootCandidates=@($rootPath);if([IO.Path]::GetExtension($rootName) -notin @('.psm1','.ps1','.dll')){$rootCandidates+=@($rootPath+'.psm1',$rootPath+'.ps1',$rootPath+'.dll');if($PSHOME){$rootCandidates+=@((Join-Path $PSHOME $rootName),(Join-Path $PSHOME ($rootName+'.dll')))}};$rootAccepted=$false;foreach($rootCandidate in $rootCandidates){$rootSafe=Get-WorkerSafeLocalPath $rootCandidate;if($rootSafe.Allowed -and [IO.File]::Exists($rootSafe.Path)){$rootAccepted=$true;break}};if(-not $rootAccepted){throw 'RootModuleNotGuardedLocal'}};foreach($dependencyKey in @('NestedModules','RequiredAssemblies')){$dependencyMatch=[regex]::Match($manifestText,'(?im)^\s*'+$dependencyKey+'\s*=\s*(?<value>[^\r\n]+)');if($dependencyMatch.Success){foreach($entry in [regex]::Matches($dependencyMatch.Groups['value'].Value,'[''\"](?<file>[^''\"]+)[''\"]')){$dependencyName=$entry.Groups['file'].Value;if($dependencyName -match '^(?:\\\\|//|[A-Za-z]:)'){throw ('Absolute'+$dependencyKey+'PathBlocked')};$dependencyCandidates=@((Join-Path $base $dependencyName));if($dependencyKey -eq 'RequiredAssemblies' -and $PSHOME){$dependencyCandidates+=Join-Path $PSHOME $dependencyName};$dependencyAccepted=$false;foreach($dependencyPath in $dependencyCandidates){$dependencySafe=Get-WorkerSafeLocalPath $dependencyPath;if($dependencySafe.Allowed -and [IO.File]::Exists($dependencySafe.Path)){$dependencyAccepted=$true;break}};if(-not $dependencyAccepted){throw ($dependencyKey+'NotGuardedLocal')}}}};Import-Module -Name $safe.Path -Force -ErrorAction Stop;break}catch{$reason='LocalCapabilityModuleImportFailed';if($_.Exception.Message -match 'DependencyResolutionNotGuarded|AbsoluteRootModuleBlocked|RootModuleNotGuardedLocal|AbsoluteNestedModulesPathBlocked|AbsoluteRequiredAssembliesPathBlocked|NestedModulesNotGuardedLocal|RequiredAssembliesNotGuardedLocal|ManifestSizeBudgetExceeded'){$reason=$_.Exception.Message};$gaps.Add([pscustomobject]@{Collector='NativeInventory';Operation='CapabilityModuleImport';ReasonCode=$reason;Path=$manifest;ItemId=$name;Action='ImportFailed'});break}}};@($gaps.ToArray())}
$script:WsmDeveloperProbeWorkerStage='CollectorDispatch'
 $cimCapabilityGaps=@()
 if($CollectorId -in @('PlatformIdentity','LocalVolumes')){
   $script:WsmDeveloperProbeWorkerStage='ExplicitCimModuleImport'
   $cimImported=$false
   $trustedCimRoots=@()
   if($env:windir){$trustedCimRoots+=Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\Modules\CimCmdlets'}
   if($PSHOME){$trustedCimRoots+=Join-Path $PSHOME 'Modules\CimCmdlets'}
   $cimManifestCandidates=@()
   if($PSHOME){$cimManifestCandidates+=Join-Path $PSHOME 'Modules\CimCmdlets\CimCmdlets.psd1'}
   if($env:windir){$cimManifestCandidates+=Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\Modules\CimCmdlets\CimCmdlets.psd1'}
   foreach($candidateManifest in $cimManifestCandidates){$candidateCheck=Get-WorkerSafeLocalPath $candidateManifest;if(-not $candidateCheck.Allowed){$cimCapabilityGaps+=@([pscustomobject]@{Operation='CimCapabilityImport';ReasonCode=$candidateCheck.ReasonCode;Path=$candidateManifest});continue};$trustedRoot=$false;foreach($trustedCimRoot in $trustedCimRoots){$trustedPrefix=[IO.Path]::GetFullPath($trustedCimRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar;if($candidateCheck.Path.StartsWith($trustedPrefix,[StringComparison]::OrdinalIgnoreCase)){$trustedRoot=$true;break}};if(-not $trustedRoot){$cimCapabilityGaps+=@([pscustomobject]@{Operation='CimCapabilityImport';ReasonCode='CimModuleOutsideInboxRoot';Path=$candidateManifest});continue};$manifestInfo=[IO.FileInfo]::new($candidateCheck.Path);if(-not $manifestInfo.Exists -or $manifestInfo.Length -gt 1048576){$cimCapabilityGaps+=@([pscustomobject]@{Operation='CimCapabilityImport';ReasonCode='CimManifestUnavailableOrTooLarge';Path=$candidateManifest});continue};try{Import-Module -Name $candidateCheck.Path -Force -ErrorAction Stop;if(Get-Command Get-CimInstance -CommandType Cmdlet -ErrorAction SilentlyContinue -ListImported){$cimImported=$true;break}}catch{$cimCapabilityGaps+=@([pscustomobject]@{Operation='CimCapabilityImport';ReasonCode='TrustedCimModuleImportFailed';Path=$candidateManifest;ErrorType=$_.Exception.GetType().Name})}}
   if(-not $cimImported){throw ('The trusted inbox CimCmdlets module did not provide Get-CimInstance; capability gaps='+(@($cimCapabilityGaps|ConvertTo-Json -Compress))) }
 }
switch($CollectorId){
 'PlatformIdentity' {
   $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop;$edition='Unknown';$installation='Unknown';try{$version=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop;$edition=[string]$version.EditionID;$installation=[string]$version.InstallationType}catch{};$architecture=[string]$env:PROCESSOR_ARCHITECTURE;if($architecture -eq 'AMD64'){$architecture='x64'}elseif($architecture -eq 'ARM64'){$architecture='Arm64'};$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
   [pscustomobject]@{OS=[string]$os.Caption;Version=[string]$os.Version;Build=[string]$os.BuildNumber;Edition=$edition;InstallationType=$installation;Architecture=$architecture;PowerShellVersion=$PSVersionTable.PSVersion.ToString();PowerShellEdition=$PSVersionTable.PSEdition;LanguageMode=[string]$ExecutionContext.SessionState.LanguageMode;IsServer=([int]$os.ProductType -ne 1);Is64Bit=[Environment]::Is64BitProcess;Administrator=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);HostAlias=('['+(Get-WorkerAlias ([string]$env:COMPUTERNAME) 'host')+']')}
 }
 'CommandsModules' {
   $moduleSnapshot=Get-WorkerLocalModuleSnapshot
   $names=@('Get-ScheduledTask','Export-ScheduledTask','Get-ScheduledTaskInfo','Get-Website','Get-WebAppPoolState','Get-SmbShare','Get-SmbShareAccess','Get-Acl','Get-WindowsFeature','Get-CimInstance','Get-ItemProperty','Get-ChildItem','Get-Volume','Get-NetIPAddress','Get-NetRoute','Get-NetFirewallRule')
   $moduleNames=@('ScheduledTasks','WebAdministration','SmbShare','ServerManager','NetSecurity');$availableModules=@{};foreach($moduleName in $moduleNames){$module=@($moduleSnapshot.Rows|Where-Object Name -CEQ $moduleName|Sort-Object {try{[version]$_.Version}catch{[version]'0.0'}} -Descending|Select-Object -First 1);if($module.Count){$availableModules[$moduleName]=$module[0]}}
   $moduleHints=@{'Get-ScheduledTask'='ScheduledTasks';'Export-ScheduledTask'='ScheduledTasks';'Get-ScheduledTaskInfo'='ScheduledTasks';'Get-Website'='WebAdministration';'Get-WebAppPoolState'='WebAdministration';'Get-SmbShare'='SmbShare';'Get-SmbShareAccess'='SmbShare';'Get-WindowsFeature'='ServerManager';'Get-NetFirewallRule'='NetSecurity'}
   $commands=@(foreach($name in $names){$cmd=Get-Command $name -ErrorAction SilentlyContinue -ListImported;$moduleName=if($cmd){[string]$cmd.Source}elseif($moduleHints.ContainsKey($name)){[string]$moduleHints[$name]}else{''};$installed=$false;$installedCommand=$null;if($moduleName -and $availableModules.ContainsKey($moduleName)){$candidate=$availableModules[$moduleName];if(@($candidate.ExportedCommandNames) -contains $name){$installed=$true;$installedCommand='ManifestExport'}};[pscustomobject]@{Name=$name;Loaded=[bool]$cmd;DiscoverableInstalled=$installed;Available=([bool]$cmd -or $installed);CapabilityStatus=$(if($cmd){'Loaded'}elseif($installed){'AvailableInInstalledModule'}else{'Unavailable'});CommandType=$(if($cmd){[string]$cmd.CommandType}elseif($installedCommand){$installedCommand}else{'Unavailable'});Module=$moduleName}})
   $modules=@(foreach($moduleName in $moduleNames){if($availableModules.ContainsKey($moduleName)){$module=$availableModules[$moduleName];[pscustomobject]@{Name=$module.Name;Version=$module.Version;DiscoverableInstalled=$true;ExportedCommandCount=@($module.ExportedCommandNames).Count}}else{[pscustomobject]@{Name=$moduleName;Version=$null;DiscoverableInstalled=$false;ExportedCommandCount=0}}})
   [pscustomobject]@{Status=$moduleSnapshot.Status;ReasonCode=$(if($moduleSnapshot.Gaps.Count){'LocalModuleDiscoveryIncomplete'}else{$null});Commands=$commands;Modules=$modules;ScopeGaps=@($moduleSnapshot.Gaps)}
 }
 'LocalVolumes' {
   $rows=@(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | ForEach-Object {$root=[string]$_.DeviceID+'\';$canonical=$false;try{$canonical=[IO.Path]::GetFullPath($root).Length -gt 2}catch{};[pscustomobject]@{DriveAlias=('volume-'+[string]$_.DeviceID.TrimEnd(':'));RootAlias=(Get-WorkerAlias $root 'path');FileSystem=[string]$_.FileSystem;SizeBytes=$(if($_.Size){[long]$_.Size}else{$null});FreeBytes=$(if($_.FreeSpace){[long]$_.FreeSpace}else{$null});VolumeLabelPresent=[bool]$_.VolumeName;RootReadable=[bool](Test-Path -LiteralPath $root);PathCanonicalizationAvailable=$canonical;WriteTest='NotRunReadOnlyProbe'}})
   [pscustomobject]@{Volumes=$rows;Scope='LocalFixedVolumesOnly';RemoteEnumeration=$false;ReparseTraversal=$false;WriteCapability='NotTestedBecauseProbeIsReadOnly'}
 }
 'NativeInventory' {
   $script:WsmDeveloperProbeWorkerStage='LocalModuleDiscovery'
   $localModuleSnapshot=Get-WorkerLocalModuleSnapshot
   foreach($originalRoot in @($OriginalModulePath -split [regex]::Escape([IO.Path]::PathSeparator)|Where-Object {$_})){$originalCheck=Get-WorkerSafeLocalPath $originalRoot;if(-not $originalCheck.Allowed){$localModuleSnapshot.Gaps=@($localModuleSnapshot.Gaps)+@([pscustomobject]@{Path=$originalRoot;ReasonCode=$originalCheck.ReasonCode;Action='ExcludedBeforeChildModuleLoading'})}elseif([IO.Directory]::Exists($originalCheck.Path) -and -not @(($env:PSModulePath -split [regex]::Escape([IO.Path]::PathSeparator))|Where-Object {[IO.Path]::GetFullPath($_) -ieq [IO.Path]::GetFullPath($originalCheck.Path)}).Count){$localModuleSnapshot.Gaps=@($localModuleSnapshot.Gaps)+@([pscustomobject]@{Path=$originalCheck.Path;ReasonCode='ModuleRootExcludedByIsolation';Action='ExcludedBeforeChildModuleLoading'})}}
   $script:WsmDeveloperProbeWorkerStage='DeveloperProbeHelperLoad'
   . (Join-Path (Split-Path $ModulePath -Parent) 'DeveloperProbe.ps1')
   $script:WsmDeveloperProbeWorkerStage='MigrationModuleImport'
   Import-Module -Name $ModulePath -Force -ErrorAction Stop
   $module=Get-Module WindowsServerMigration | Select-Object -First 1
   $script:WsmDeveloperProbeWorkerStage='InstallPathAndDiscoveryGuards'
   Install-WsmDeveloperProbeInventoryGuards -Module $module -Salt $Salt
   $script:WsmDeveloperProbeWorkerStage='ExplicitCapabilityModuleImports'
   $cimModuleGaps=@(Import-WorkerSafeCapabilityModules $localModuleSnapshot @('CimCmdlets'))
   $script:WsmDeveloperProbeWorkerStage='NativePreflight'
   $pre=Get-WsmPreflight
   if(-not $pre.IsServer){return [pscustomobject]@{Status='NotApplicable';ReasonCode='WindowsServerRequired';Capability=@{IsServer=$false;Administrator=$pre.Administrator;Is64Bit=$pre.Is64Bit}}}
   if(-not $pre.Administrator){return [pscustomobject]@{Status='PermissionDenied';ReasonCode='AdministratorRequired';Capability=@{IsServer=$true;Administrator=$false;Is64Bit=$pre.Is64Bit}}}
   if(-not $pre.Is64Bit){return [pscustomobject]@{Status='NotApplicable';ReasonCode='64BitPowerShellRequired';Capability=@{IsServer=$true;Administrator=$true;Is64Bit=$false}}}
   if([string]$ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage'){return [pscustomobject]@{Status='NotApplicable';ReasonCode='FullLanguageRequired';Capability=@{IsServer=$true;Administrator=$true;Is64Bit=$true;FullLanguage=$false}}}
   $capabilityModuleGaps=@($cimModuleGaps)+@(Import-WorkerSafeCapabilityModules $localModuleSnapshot @('ScheduledTasks','WebAdministration','SmbShare','ServerManager','NetSecurity','DFSN','DFSR','NFS','MSMQ','DnsServer','DhcpServer','AppLocker'))
   foreach($coreModuleName in @('Microsoft.PowerShell.Management','Microsoft.PowerShell.Utility')){$script:WsmDeveloperProbeWorkerStage='TrustedCoreModuleImport:'+ $coreModuleName;$coreManifest=Join-Path $PSHOME ('Modules\'+$coreModuleName+'\'+$coreModuleName+'.psd1');if(-not [IO.File]::Exists($coreManifest) -and $env:windir){$coreManifest=Join-Path $env:windir ('System32\WindowsPowerShell\v1.0\Modules\'+$coreModuleName+'\'+$coreModuleName+'.psd1')};$coreSafe=Get-WorkerSafeLocalPath $coreManifest;if(-not $coreSafe.Allowed -or -not [IO.File]::Exists($coreSafe.Path)){throw ('Trusted local core module unavailable: '+$coreModuleName)};Import-Module -Name $coreSafe.Path -Force -ErrorAction Stop}
   if(-not [IO.Directory]::Exists($RawRoot)){[void][IO.Directory]::CreateDirectory($RawRoot)}
   $script:WsmDeveloperProbeWorkerStage='ExportNativeInventory'
   $captured=Export-WsmInventory -OutputDirectory $RawRoot -IncludeSoftwareCatalog -DeepDiscovery
   $script:WsmDeveloperProbeWorkerStage='ReadNativeInventoryProjectionInput'
   $actualHash=(Get-FileHash -LiteralPath $captured.Path -Algorithm SHA256).Hash.ToLowerInvariant();if($actualHash -cne [string]$captured.SHA256){throw 'Native inventory hash changed before the sanitized summary was read.'};$inventory=[IO.File]::ReadAllText($captured.Path)|ConvertFrom-Json
   $scopeGaps=@(Get-WsmDeveloperProbeInventoryScopeGaps -Module $module)+@($localModuleSnapshot.Gaps)+@($capabilityModuleGaps)
   $incompleteCount=if($captured.PSObject.Properties['Incomplete']){[int]$captured.Incomplete}else{-1}
   [pscustomobject]@{Status='Captured';InventoryPath=[string]$captured.Path;InventorySHA256=[string]$captured.SHA256;InventoryIncompleteCount=$incompleteCount;ScopeGaps=$scopeGaps;RawEvidence='ProtectedLocalOnly'}
 }
 'HttpProbe' {
   Import-Module -Name $ModulePath -Force -ErrorAction Stop
   if(-not $Origin){return [pscustomobject]@{Status='NotApplicable';ReasonCode='NoOriginSupplied'}}
   $out=Join-Path $RawRoot 'http';if(-not [IO.Directory]::Exists($out)){[void][IO.Directory]::CreateDirectory($out)}
   $result=Export-WsmAssistiveHttpProbe -Origin ([uri]$Origin) -OutputPath (Join-Path $out 'http-probe.txt')
   $safeAssets=@(foreach($asset in @($result.Assets)){[pscustomobject]@{RouteAlias=(Get-WorkerAlias ([string]$asset.Route) 'route');Status=[string]$asset.Status;ExpectedBytes=$asset.ExpectedBytes;ObservedBytes=$asset.ObservedBytes;LocalSHA256=$asset.LocalSHA256;ObservedSHA256=$asset.ObservedSHA256;BodyMatchesDisk=[bool]$asset.BodyMatchesDisk;HeadersMatchExpected=[bool]$asset.HeadersMatchExpected;TransportErrorType=$(if($asset.TransportError){[string]$asset.TransportError}else{$null})}})
   [pscustomobject]@{Status=[string]$result.Status;AssetCount=$safeAssets.Count;Assets=$safeAssets;ErrorType=$(if($result.Error){[string]$result.Error}else{$null})}
 }
 default {throw 'Unknown developer probe collector.'}
}
'@
    if($CollectorId -eq 'NativeInventory' -and -not $Adapter){
        $enginePath=if($PSVersionTable.PSEdition -eq 'Core'){Join-Path $PSHOME 'pwsh.exe'}else{Join-Path $PSHOME 'powershell.exe'}
        if(-not [IO.File]::Exists($enginePath)){throw 'Isolated native worker PowerShell executable is unavailable.'}
        $moduleRoots=New-Object 'System.Collections.Generic.List[string]'
        foreach($candidateRoot in @((Join-Path $PSHOME 'Modules'),$(if($env:windir){Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\Modules'}))){if(-not $candidateRoot){continue};$safeRoot=Test-WsmDeveloperProbeSafeProcessModuleRoot $candidateRoot;if($safeRoot.Allowed -and [IO.Directory]::Exists($safeRoot.Path) -and -not @($moduleRoots|Where-Object {$_ -ieq $safeRoot.Path}).Count){$moduleRoots.Add($safeRoot.Path)}}
        $childModulePath=[string]::Join([IO.Path]::PathSeparator,$moduleRoots.ToArray())
        $resultPath=Join-Path $RawRoot ('developer-probe-worker-'+[Guid]::NewGuid().ToString('N')+'.json')
        $encode={param([string]$Value)[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$Value))}.GetNewClosure()
        $encodedScript=& $encode $script;$encodedArgs=@((& $encode $ModulePath),(& $encode $CollectorId),(& $encode $Role),(& $encode $Origin),(& $encode $RawRoot),(& $encode $Salt),(& $encode $(if($Adapter){$Adapter.ToString()}else{''})),(& $encode $env:PSModulePath),(& $encode $resultPath))
        $runner='$decode={param([string]$value)[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($value))};$source=&$decode ''@SOURCE@'';$block=[scriptblock]::Create($source);$values=@(@ARGS@|ForEach-Object {&$decode $_});try{$output=@(& $block $values[0] $values[1] $values[2] $values[3] $values[4] $values[5] $values[6] ''All'' $values[7]);$envelope=[pscustomobject]@{Success=$true;Output=$output}}catch{$envelope=[pscustomobject]@{Success=$false;ErrorType=$_.Exception.GetType().Name;ErrorMessage=[string]$_.Exception.Message;ErrorId=[string]$_.FullyQualifiedErrorId}};$json=ConvertTo-Json -InputObject $envelope -Depth 60 -Compress;[IO.File]::WriteAllText((&$decode ''@RESULT@''),$json,(New-Object Text.UTF8Encoding($false)));if(-not $envelope.Success){exit 1}'
        $runner=$runner.Replace('@SOURCE@',$encodedScript).Replace('@ARGS@',([string]::Join(',',@($encodedArgs[0..7]|ForEach-Object {"'$_'"})))).Replace('@RESULT@',$encodedArgs[8])
        $startInfo=New-Object Diagnostics.ProcessStartInfo;$startInfo.FileName=$enginePath;$startInfo.Arguments='-NoLogo -NoProfile -NonInteractive -Command -';$startInfo.UseShellExecute=$false;$startInfo.CreateNoWindow=$true;$startInfo.RedirectStandardInput=$true;$startInfo.RedirectStandardOutput=$true;$startInfo.RedirectStandardError=$true
        $startInfo.EnvironmentVariables['PSModulePath']=$childModulePath
        $process=New-Object Diagnostics.Process;$process.StartInfo=$startInfo
        if(-not $process.Start()){throw 'Unable to start isolated native probe process.'}
        $null=$process.BeginOutputReadLine();$null=$process.BeginErrorReadLine();$process.StandardInput.WriteLine($runner);$process.StandardInput.Close()
        $async=[pscustomobject]@{Process=$process};$async|Add-Member -MemberType ScriptProperty -Name IsCompleted -Value {$this.Process.HasExited}
        return [pscustomobject]@{Process=$process;ResultPath=$resultPath;RawRoot=$RawRoot;ChildModulePath=$childModulePath;Async=$async;PowerShell=$null;Runspace=$null}
    }
    [void]$powershell.AddScript($script).AddArgument($ModulePath).AddArgument($CollectorId).AddArgument($Role).AddArgument($Origin).AddArgument($RawRoot).AddArgument($Salt).AddArgument($(if($Adapter){$Adapter.ToString()}else{''})).AddArgument('None')
    [pscustomobject]@{PowerShell=$powershell;Runspace=$runspace;Async=$powershell.BeginInvoke()}
}

function Stop-WsmDeveloperProbeWorker($Worker){if(-not $Worker){return};if($Worker.PSObject.Properties['Process'] -and $Worker.Process){try{if(-not $Worker.Process.HasExited){$Worker.Process.Kill();[void]$Worker.Process.WaitForExit(5000)}}catch{};return};if($Worker.PSObject.Properties['PowerShell'] -and $Worker.PowerShell){try{$Worker.PowerShell.Stop()}catch{}}}
function Receive-WsmDeveloperProbeWorkerOutput($Worker,[long]$MaximumEnvelopeBytes=16777216){if($Worker -and $Worker.PSObject.Properties['Process'] -and $Worker.Process){if(-not $Worker.Process.HasExited){throw 'Native probe process has not completed.'};$resultPath=[IO.Path]::GetFullPath([string]$Worker.ResultPath);$rawRoot=[IO.Path]::GetFullPath([string]$Worker.RawRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar;if(-not $resultPath.StartsWith($rawRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Native probe result envelope escaped its protected raw root.'};Assert-WsmNoReparse $resultPath;if(-not [IO.File]::Exists($resultPath)){throw ('Native probe process exited without a result file (exit '+$Worker.Process.ExitCode+').')};$resultInfo=[IO.FileInfo]::new($resultPath);if($resultInfo.Length -gt $MaximumEnvelopeBytes){throw 'Native probe result envelope exceeds its bounded read size.'};$envelopeBytes=[IO.File]::ReadAllBytes($resultPath);if($envelopeBytes.Length -gt $MaximumEnvelopeBytes){throw 'Native probe result envelope grew beyond its bounded read size.'};$envelope=(New-Object Text.UTF8Encoding($false,$true)).GetString($envelopeBytes)|ConvertFrom-Json;if(-not $envelope.Success){throw ([string]$envelope.ErrorType+': '+[string]$envelope.ErrorMessage)};return @($envelope.Output)};if($Worker -and $Worker.PSObject.Properties['PowerShell'] -and $Worker.PowerShell){$output=@($Worker.PowerShell.EndInvoke($Worker.Async));$errors=@($Worker.PowerShell.Streams.Error);if($errors.Count){throw $errors[0].Exception};return $output};return @()}
function Dispose-WsmDeveloperProbeWorker($Worker){if(-not $Worker){return};if($Worker.PSObject.Properties['Process'] -and $Worker.Process){try{Stop-WsmDeveloperProbeWorker $Worker}catch{};try{$Worker.Process.Dispose()}catch{};return};if($Worker.PSObject.Properties['PowerShell'] -and $Worker.PowerShell){try{$Worker.PowerShell.Dispose()}catch{}};if($Worker.PSObject.Properties['Runspace'] -and $Worker.Runspace){try{$Worker.Runspace.Close();$Worker.Runspace.Dispose()}catch{}}}

function Export-WsmDeveloperProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Workspace,
        [ValidateSet('Source','Target','Manager')][string]$Role='Manager',
        [string]$Origin,
        [string]$PairId,
        [ValidateRange(1,300)][int]$CollectorTimeoutSeconds=30,
        [ValidateRange(16384,67108864)][long]$MaximumOutputBytes=4194304,
        [psobject]$CancellationToken,
        [Parameter(DontShow)][hashtable]$CollectorAdapter
    )
    $ErrorActionPreference='Stop'
    if([string]::IsNullOrWhiteSpace($Workspace) -or -not [IO.Path]::IsPathRooted($Workspace)){throw 'Workspace must be an absolute local path.'}
    $workspacePath=[IO.Path]::GetFullPath($Workspace);$rootPath=[IO.Path]::GetPathRoot($workspacePath)
    if($workspacePath.StartsWith('\\') -or $rootPath.StartsWith('\\')){throw 'Developer probe output must stay on a local volume.'}
    if($CancellationToken -and [string]$CancellationToken.Kind -ceq 'DeveloperProbeCancellationToken'){$expectedCancellation=Get-WsmDeveloperProbeCancellationPath $workspacePath ([string]$CancellationToken.OperationId);if([IO.Path]::GetFullPath([string]$CancellationToken.Workspace) -ine $workspacePath -or [IO.Path]::GetFullPath([string]$CancellationToken.RequestPath) -ine [IO.Path]::GetFullPath($expectedCancellation)){throw 'Developer probe cancellation token does not belong to this workspace operation.'}}
    Assert-WsmNoReparse $workspacePath
    if(-not [IO.Directory]::Exists($workspacePath)){[void][IO.Directory]::CreateDirectory($workspacePath);Protect-WsmDirectory $workspacePath}
    $outputRoot=Join-Path $workspacePath 'developer-probes';Assert-WsmNoReparse $outputRoot
    if(-not [IO.Directory]::Exists($outputRoot)){[void][IO.Directory]::CreateDirectory($outputRoot);Protect-WsmDirectory $outputRoot}
    $runId=[Guid]::NewGuid().ToString();$runRoot=Join-Path $outputRoot $runId;[void][IO.Directory]::CreateDirectory($runRoot);Protect-WsmDirectory $runRoot
    $rawRoot=Join-Path $runRoot 'protected-raw';[void][IO.Directory]::CreateDirectory($rawRoot);Protect-WsmDirectory $rawRoot
    $module=Get-Module WindowsServerMigration | Select-Object -First 1
    $modulePath=if($module){[string]$module.Path}else{Join-Path $PSScriptRoot 'WindowsServerMigration.psd1'}
    $manifest=@(
        [pscustomobject]@{Id='PlatformIdentity';Applicability='All roles';Required=$true},
        [pscustomobject]@{Id='CommandsModules';Applicability='All roles';Required=$true},
        [pscustomobject]@{Id='LocalVolumes';Applicability='All roles';Required=$true},
        [pscustomobject]@{Id='NativeInventory';Applicability='Elevated 64-bit Windows Server';Required=$true},
        [pscustomobject]@{Id='HttpProbe';Applicability='Origin supplied';Required=$false}
    )
    $results=New-Object 'System.Collections.Generic.List[object]';$workers=New-Object 'System.Collections.Generic.List[object]'
    $context=[ordered]@{SchemaVersion='1.0';RunId=$runId;CreatedUtc=[DateTime]::UtcNow.ToString('o');Role=$Role;PairAlias=$(if($PairId){Get-WsmDeveloperProbeSafeAlias $PairId 'pair' $runId}else{$null});FormatVersion='1.0';ToolVersion=[string]$script:ToolVersion;ToolFingerprint=(Get-WsmToolFingerprint);Mode='ReadOnly';ProductionQualified=$false;BusinessValidated=$false;RedactionPolicy=@('credentials','private keys','wallets','XML and scripts','arguments and command lines','user and account identifiers','host names','absolute paths','sensitive values embedded in errors and headers')}
    $collectors=@('PlatformIdentity','CommandsModules','LocalVolumes','NativeInventory');if($Origin){$collectors+=@('HttpProbe')}
    try{
        $driveInfo=[IO.DriveInfo]::new($rootPath);$availableBytes=if($driveInfo.IsReady){[long]$driveInfo.AvailableFreeSpace}else{[long]0};$rawEvidenceBudgetBytes=[long][Math]::Min(134217728,[Math]::Max(16777216,($MaximumOutputBytes*4)))
        foreach($collectorId in $collectors){
            if($CancellationToken -and (Test-WsmDeveloperProbeCancellationRequested $CancellationToken $workspacePath)){break}
            $start=[DateTime]::UtcNow.ToString('o');$adapter=$null;if($CollectorAdapter -and $CollectorAdapter.ContainsKey($collectorId)){$adapter=[scriptblock]$CollectorAdapter[$collectorId]}
            if($collectorId -eq 'NativeInventory' -and $availableBytes -lt ($rawEvidenceBudgetBytes+134217728)){$results.Add([pscustomobject]@{Id=$collectorId;Status='NotApplicable';StartedUtc=$start;CompletedUtc=[DateTime]::UtcNow.ToString('o');DurationMs=0;ReasonCode='InsufficientLocalSpace';Data=[pscustomobject]@{AvailableBytes=$availableBytes;RequiredBytes=($rawEvidenceBudgetBytes+134217728)}});continue}
            $worker=New-WsmDeveloperProbeWorker $modulePath $collectorId $Role $Origin $rawRoot $runId $adapter
            $workers.Add([pscustomobject]@{Id=$collectorId;StartedUtc=$start;Worker=$worker})
            $deadline=[Diagnostics.Stopwatch]::StartNew()
            $rawBudgetExceeded=$false
            while(-not $worker.Async.IsCompleted -and $deadline.Elapsed.TotalSeconds -lt $CollectorTimeoutSeconds){
                if($CancellationToken -and (Test-WsmDeveloperProbeCancellationRequested $CancellationToken $workspacePath)){break}
                if($collectorId -eq 'NativeInventory'){$rawBytes=Get-WsmDeveloperProbeRawBytes $rawRoot;if($rawBytes -gt $rawEvidenceBudgetBytes){$rawBudgetExceeded=$true;break}}
                Start-Sleep -Milliseconds 40
            }
            $cancelled=($CancellationToken -and (Test-WsmDeveloperProbeCancellationRequested $CancellationToken $workspacePath))
            if($cancelled -or $rawBudgetExceeded -or -not $worker.Async.IsCompleted){
                Stop-WsmDeveloperProbeWorker $worker
                $status=if($cancelled){'Cancelled'}elseif($rawBudgetExceeded){'Partial'}else{'TimedOut'};$reason=if($cancelled){'CancellationRequested'}elseif($rawBudgetExceeded){'RawEvidenceBudgetExceeded'}else{'CollectorTimeout'}
                $stopData=if($rawBudgetExceeded){[pscustomobject]@{ObservedBytes=(Get-WsmDeveloperProbeRawBytes $rawRoot);BudgetBytes=$rawEvidenceBudgetBytes}}elseif($worker.PSObject.Properties['Process'] -and $worker.Process){[pscustomobject]@{OwnedProcessId=$worker.Process.Id;OwnedProcessExitObserved=[bool]$worker.Process.HasExited;TerminationScope='OwnedProcessOnly';ChildProcessTerminationVerified=$false}}else{$null}
                $results.Add([pscustomobject]@{Id=$collectorId;Status=$status;StartedUtc=$start;CompletedUtc=[DateTime]::UtcNow.ToString('o');DurationMs=[long]$deadline.ElapsedMilliseconds;ReasonCode=$reason;Data=$stopData})
                if($cancelled){break};continue
            }
            try{
                $output=@(Receive-WsmDeveloperProbeWorkerOutput $worker);$errors=@(if($worker.PowerShell){$worker.PowerShell.Streams.Error});$data=$null
                if($errors.Count){$status='Failed';$reasonCode='CollectorFailed';$errorRecord=$errors[0];$failureType=$errorRecord.Exception.GetType().Name;$message=[string]$errorRecord.Exception.Message;$errorId=[string]$errorRecord.FullyQualifiedErrorId;$data=[pscustomobject]@{ErrorType=$failureType;ErrorSummary=(ConvertTo-WsmDeveloperProbeSafeText $message $runId);ErrorId=(ConvertTo-WsmDeveloperProbeSafeText $errorId $runId)}}
                elseif($output.Count -eq 0){$status='Failed';$reasonCode='NoCollectorResult';$data=[pscustomobject]@{ErrorType='NoCollectorResult'}}
                else{$rawOutput=$output[-1];if($collectorId -eq 'NativeInventory' -and [string]$rawOutput.Status -eq 'Captured'){$observedRawBytes=Get-WsmDeveloperProbeRawBytes $rawRoot;if($observedRawBytes -gt $rawEvidenceBudgetBytes){$budgetData=[pscustomobject]@{Status='Partial';ReasonCode='RawEvidenceBudgetExceeded';ObservedBytes=$observedRawBytes;BudgetBytes=$rawEvidenceBudgetBytes;RawEvidence='ProtectedLocalOnly'};$safeBudgetData=ConvertTo-WsmDeveloperProbeSafeObject $budgetData 0 $runId;$results.Add([pscustomobject]@{Id=$collectorId;Status='Partial';StartedUtc=$start;CompletedUtc=[DateTime]::UtcNow.ToString('o');DurationMs=[long]$deadline.ElapsedMilliseconds;ReasonCode='RawEvidenceBudgetExceeded';Data=$safeBudgetData});continue};if($rawOutput.PSObject.Properties['InventoryPath']){$inventoryPath=[IO.Path]::GetFullPath([string]$rawOutput.InventoryPath);$rawPrefix=[IO.Path]::GetFullPath($rawRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar;if(-not $inventoryPath.StartsWith($rawPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Native inventory output path escaped the protected probe root.'};Assert-WsmNoReparse $inventoryPath;$inventoryInfo=New-Object IO.FileInfo($inventoryPath);if(-not $inventoryInfo.Exists -or $inventoryInfo.Length -gt $rawEvidenceBudgetBytes){throw 'Native inventory source exceeded its protected evidence read budget.'};$actualHash=(Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant();if($actualHash -cne [string]$rawOutput.InventorySHA256){throw 'Native inventory hash changed before the sanitized summary was read.'};$rawOutput|Add-Member -MemberType NoteProperty -Name Inventory -Value ([IO.File]::ReadAllText($inventoryPath)|ConvertFrom-Json) -Force}elseif(-not $rawOutput.PSObject.Properties['Inventory']){throw 'Native inventory source was not available for structured projection.'};$nativeScopeGaps=@();if($rawOutput.PSObject.Properties['ScopeGaps']){$nativeScopeGaps=@($rawOutput.ScopeGaps)};$nativeIncomplete=-1;if($rawOutput.PSObject.Properties['InventoryIncompleteCount']){$nativeIncomplete=[int]$rawOutput.InventoryIncompleteCount};$rawOutput=ConvertTo-WsmDeveloperProbeInventoryProjection $rawOutput.Inventory ([string]$rawOutput.InventorySHA256) $runId $nativeScopeGaps $nativeIncomplete};$data=ConvertTo-WsmDeveloperProbeSafeObject $rawOutput 0 $runId;$dataJson=$data|ConvertTo-Json -Depth 12 -Compress;$dataBytes=(New-Object Text.UTF8Encoding($false)).GetBytes($dataJson);if($dataBytes.Length -gt $MaximumOutputBytes){$data=[pscustomobject]@{Truncated=$true;OriginalSerializedBytes=$dataBytes.Length;LimitBytes=$MaximumOutputBytes};$status='Partial';$reasonCode='CollectorOutputLimit'}elseif($dataJson.Contains('…[TRUNCATED]') -or $dataJson.Contains('[ITEM-LIMIT]') -or $dataJson.Contains('[DEPTH-LIMIT]')){$status='Partial';$reasonCode='CollectorValueTruncated'}else{$status='Completed';$reasonCode=$null};if($data.PSObject.Properties['Status'] -and [string]$data.Status -in @('NotApplicable','PermissionDenied','Partial')){$status=[string]$data.Status;$reasonCode=if($data.PSObject.Properties['ReasonCode']){[string]$data.ReasonCode}else{if($status -eq 'Partial'){'CollectorReportedPartial'}else{$null}}}}
                if($data -and $data.PSObject.Properties['ErrorType']){$data=ConvertTo-WsmDeveloperProbeSafeObject $data 0 $runId}
                if($collectorId -eq 'NativeInventory' -and $status -eq 'Completed' -and (Get-WsmDeveloperProbeRawBytes $rawRoot) -gt $rawEvidenceBudgetBytes){$status='Partial';$reasonCode='RawEvidenceBudgetExceeded'}
                $results.Add([pscustomobject]@{Id=$collectorId;Status=$status;StartedUtc=$start;CompletedUtc=[DateTime]::UtcNow.ToString('o');DurationMs=[long]$deadline.ElapsedMilliseconds;ReasonCode=$reasonCode;Data=$data})
            }catch{$message=ConvertTo-WsmDeveloperProbeSafeText ([string]$_.Exception.Message) $runId;$failureData=ConvertTo-WsmDeveloperProbeSafeObject ([pscustomobject]@{ErrorType=$_.Exception.GetType().Name;ErrorSummary=$message;ErrorId=(ConvertTo-WsmDeveloperProbeSafeText ([string]$_.FullyQualifiedErrorId) $runId)}) 0 $runId;$results.Add([pscustomobject]@{Id=$collectorId;Status='Failed';StartedUtc=$start;CompletedUtc=[DateTime]::UtcNow.ToString('o');DurationMs=[long]$deadline.ElapsedMilliseconds;ReasonCode='CollectorFailed';Data=$failureData})}
            finally{Dispose-WsmDeveloperProbeWorker $worker}
        }
        foreach($entry in $manifest){if(-not @($results.ToArray()|Where-Object Id -CEQ $entry.Id).Count){$state=if($entry.Id -eq 'HttpProbe' -and -not $Origin){'NotApplicable'}elseif($CancellationToken -and (Test-WsmDeveloperProbeCancellationRequested $CancellationToken $workspacePath)){'Cancelled'}else{'NotScheduled'};$results.Add([pscustomobject]@{Id=$entry.Id;Status=$state;StartedUtc=$null;CompletedUtc=$null;DurationMs=0;ReasonCode=$(if($state -eq 'NotApplicable'){'NoOriginSupplied'}elseif($state -eq 'Cancelled'){'CancellationRequested'}else{'PriorCollectorCancelled'});Data=$null})}}
        $probe=[ordered]@{FormatVersion='1.0';DataModel='SanitizedDeveloperProbeProjection';ToolVersion=$context.ToolVersion;ToolFingerprint=$context.ToolFingerprint;RunId=$runId;CreatedUtc=$context.CreatedUtc;Role=$Role;PairAlias=$context.PairAlias;Mode='ReadOnly';ProductionQualified=$false;BusinessValidated=$false;ResourceLimits=[pscustomobject]@{MaximumOutputBytes=$MaximumOutputBytes;RawEvidenceBudgetBytes=$rawEvidenceBudgetBytes};RedactionPolicy=$context.RedactionPolicy;Manifest=$manifest;Collectors=@($results.ToArray());Limitations=@('Native inventory stores raw source evidence only under this protected local run directory.','ZIP contains sanitized structured summaries only.','UNC paths and reparse-point traversal are excluded.','Probe results do not qualify production or validate business behavior.')}
        $json=$probe|ConvertTo-Json -Depth 20
        $encoding=New-Object Text.UTF8Encoding($false);$bytes=$encoding.GetBytes($json)
        if($bytes.Length -gt $MaximumOutputBytes){
            foreach($row in $probe.Collectors){if($row.Data){$row.Data=ConvertTo-WsmDeveloperProbeSafeObject $row.Data 0 $runId;$row.Status='Partial';$row.ReasonCode='ArchiveOutputLimit'}}
            $probe.Limitations+=('Sanitized JSON exceeded the configured output budget of '+$MaximumOutputBytes+' bytes; data was reduced to collector statuses and summaries.')
            foreach($row in $probe.Collectors){if($row.Data -and $row.Id -ne 'NativeInventory' -and $row.Id -ne 'PlatformIdentity'){$row.Data=$null}}
            $json=$probe|ConvertTo-Json -Depth 20;$bytes=$encoding.GetBytes($json)
            if($bytes.Length -gt $MaximumOutputBytes){throw 'Sanitized developer probe metadata exceeds MaximumOutputBytes.'}
        }
        $jsonPath=Join-Path $runRoot 'probe.json';[IO.File]::WriteAllBytes($jsonPath,$bytes)
        $htmlPath=Join-Path $runRoot 'index.html';$rows=foreach($row in $probe.Collectors){'<tr><td>'+[Net.WebUtility]::HtmlEncode([string]$row.Id)+'</td><td>'+[Net.WebUtility]::HtmlEncode([string]$row.Status)+'</td><td>'+[Net.WebUtility]::HtmlEncode([string]$row.ReasonCode)+'</td><td>'+[Net.WebUtility]::HtmlEncode([string]$row.DurationMs)+'</td></tr>'}
        $page='<!doctype html><html lang="zh-Hant"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>開發者環境探測</title><style>body{font:16px/1.5 system-ui,sans-serif;max-width:72rem;margin:2rem auto;padding:0 1rem;color:#172033}table{border-collapse:collapse;width:100%}th,td{border:1px solid #bbc4ce;padding:.5rem;text-align:left;overflow-wrap:anywhere}code{word-break:break-all}</style><h1>開發者環境探測</h1><p>格式版本：1.0　執行識別：'+[Net.WebUtility]::HtmlEncode($runId)+'</p><p>模式：唯讀。結果僅描述本機觀測，不代表正式環境資格或業務驗證。</p><table><thead><tr><th>收集項目</th><th>狀態</th><th>原因</th><th>耗時毫秒</th></tr></thead><tbody>'+($rows -join '')+'</tbody></table><p>資料格式：<code>probe.json</code> 使用 <code>SanitizedDeveloperProbeProjection</code>；這是經匿名化的診斷投影，不是原生盤點 JSON。欄位保留結構、型別、狀態及包內穩定別名。</p><p>讀取示例：PowerShell 可用 <code>[IO.Compression.ZipFile]::OpenRead($path)</code> 讀取 <code>probe.json</code>，再以 <code>ConvertFrom-Json</code> 讀取 <code>Collectors</code>。</p></html>'
        [IO.File]::WriteAllText($htmlPath,$page,$encoding)
        $payloads=New-Object 'System.Collections.Generic.List[object]';[void]$payloads.Add(@{Name='probe.json';Path=$jsonPath});[void]$payloads.Add(@{Name='index.html';Path=$htmlPath});$fileIndex=New-Object 'System.Collections.Generic.List[object]'
        foreach($payload in $payloads){[void]$fileIndex.Add([pscustomobject]@{Path=[string]$payload.Name;Length=(Get-Item -LiteralPath $payload.Path).Length;SHA256=(Get-FileHash -LiteralPath $payload.Path -Algorithm SHA256).Hash.ToLowerInvariant();ContentType=$(if($payload.Name -eq 'probe.json'){'application/json'}else{'text/html; charset=utf-8'})})}
        $indexJson=ConvertTo-Json -InputObject ([object[]]$fileIndex.ToArray()) -Depth 5;$indexPath=Join-Path $runRoot 'files-index.json';[IO.File]::WriteAllText($indexPath,$indexJson,$encoding)
        $archivePath=Join-Path $runRoot 'developer-probe.zip';Add-Type -AssemblyName System.IO.Compression;Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive=[IO.Compression.ZipFile]::Open($archivePath,[IO.Compression.ZipArchiveMode]::Create)
        try{foreach($payload in $payloads){[void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$payload.Path,$payload.Name)};[void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$indexPath,'files-index.json')}finally{$archive.Dispose()}
        $archiveBytes=(Get-Item -LiteralPath $archivePath).Length
        if($archiveBytes -gt $MaximumOutputBytes){Remove-Item -LiteralPath $archivePath -Force;throw 'ZIP exceeds MaximumOutputBytes; the sanitized result was retained locally without claiming a deliverable archive.'}
        $statuses=@($results.ToArray());$counts=[ordered]@{Completed=@($statuses|Where-Object Status -CEQ Completed).Count;Partial=@($statuses|Where-Object Status -CEQ Partial).Count;PermissionDenied=@($statuses|Where-Object Status -CEQ PermissionDenied).Count;NotApplicable=@($statuses|Where-Object Status -CEQ NotApplicable).Count;TimedOut=@($statuses|Where-Object Status -CEQ TimedOut).Count;Failed=@($statuses|Where-Object Status -CEQ Failed).Count;Cancelled=@($statuses|Where-Object Status -CEQ Cancelled).Count;NotScheduled=@($statuses|Where-Object Status -CEQ NotScheduled).Count}
        $overall=if($counts.Cancelled -gt 0){'Cancelled'}elseif($counts.TimedOut -gt 0 -or $counts.Failed -gt 0 -or $counts.PermissionDenied -gt 0 -or $counts.NotScheduled -gt 0 -or $counts.Partial -gt 0){'Partial'}else{'Completed'}
        [pscustomobject]@{Path=$archivePath;SHA256=(Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant();HtmlPath=$htmlPath;RunId=$runId;Status=$overall;CollectorCounts=[pscustomobject]$counts;CollectorResults=@($statuses);FormatVersion='1.0';ArchiveBytes=$archiveBytes;MaximumOutputBytes=$MaximumOutputBytes;RawEvidenceBudgetBytes=$rawEvidenceBudgetBytes;ProductionQualified=$false;BusinessValidated=$false}
    }finally{
        foreach($owned in $workers){if($owned.Worker){if(-not $owned.Worker.Async.IsCompleted){Stop-WsmDeveloperProbeWorker $owned.Worker};Dispose-WsmDeveloperProbeWorker $owned.Worker}}
    }
}
