function ConvertTo-WsmTaskSecurityFolderPath([string]$Path,[switch]$AllowRoot) {
    if([string]::IsNullOrWhiteSpace($Path) -or $Path[0] -cne '\' -or $Path.Contains('/') -or $Path -match '[:<>"|?*\x00-\x1f]'){throw 'Invalid Task Scheduler folder path.'}
    if($Path -ceq '\'){if($AllowRoot){return '\'};throw 'The Task Scheduler root folder cannot be created or have its ACL replaced.'}
    $segments=@($Path.Trim('\').Split('\'))
    if(-not $segments.Count -or @($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -in @('.','..') }).Count){throw 'Invalid Task Scheduler folder path segment.'}
    '\'+(($segments -join '\'))+'\'
}
function ConvertTo-WsmTaskSecurityTaskName([string]$TaskName) {
    if([string]::IsNullOrWhiteSpace($TaskName) -or $TaskName -match '[\\/<>:"|?*\x00-\x1f]'){throw 'Invalid Task Scheduler task name.'}
    $TaskName
}
function ConvertTo-WsmTaskSecuritySddl([string]$Sddl) {
    if([string]::IsNullOrWhiteSpace($Sddl)){throw 'A reviewed security descriptor is required.'}
    try{$descriptor=New-Object Security.AccessControl.RawSecurityDescriptor($Sddl);$canonical=$descriptor.GetSddlForm([Security.AccessControl.AccessControlSections]::All)}catch{throw 'Task security descriptor is invalid or cannot be represented safely.'}
    if([string]::IsNullOrWhiteSpace($canonical)){throw 'Task security descriptor has no canonical SDDL representation.'}
    $canonical
}
function Get-WsmTaskSecurityDescriptorHash([string]$Sddl) {
    Get-WsmHashText (ConvertTo-WsmTaskSecuritySddl $Sddl)
}
function Get-WsmTaskSecurityFolderAncestors([string]$FolderPath) {
    $canonical=ConvertTo-WsmTaskSecurityFolderPath $FolderPath -AllowRoot
    if($canonical -ceq '\'){return @('\')}
    $segments=@($canonical.Trim('\').Split('\'));$paths=New-Object 'System.Collections.Generic.List[string]';$current='\';$paths.Add($current)
    foreach($segment in $segments){$current=$current+$segment+'\';$paths.Add($current)}
    $paths.ToArray()
}
function ConvertTo-WsmTaskSecurityFolderSpecs([object[]]$Folders) {
    if(-not $Folders -or -not $Folders.Count){throw 'At least one reviewed Task Scheduler folder is required.'}
    $byPath=@{};$entries=New-Object 'System.Collections.Generic.List[object]'
    foreach($entry in $Folders){
        if($null -eq $entry){throw 'Task folder specification cannot be null.'}
        $properties=@($entry.PSObject.Properties | ForEach-Object Name)
        foreach($required in @('Path','SecuritySddl','ExistingPolicy')){if($properties -cnotcontains $required){throw ('Task folder specification requires '+$required+'.')}}
        foreach($property in $properties){if($property -cnotin @('Path','SecuritySddl','ExistingPolicy')){throw ('Unexpected task folder specification field: '+$property)}}
        if([string]$entry.ExistingPolicy -cnotin @('VerifyExact','CreateOnly')){throw 'ExistingPolicy must be VerifyExact or CreateOnly.'}
        $path=ConvertTo-WsmTaskSecurityFolderPath ([string]$entry.Path) -AllowRoot
        if($path -ceq '\' -and [string]$entry.ExistingPolicy -cne 'VerifyExact'){throw 'The Task Scheduler root folder can only be verified; it cannot be created or claimed as owned.'}
        $sddl=ConvertTo-WsmTaskSecuritySddl ([string]$entry.SecuritySddl);$key=$path.ToUpperInvariant()
        if($byPath.ContainsKey($key)){throw 'Duplicate Task Scheduler folder specification.'}
        $depth=0;if($path -cne '\'){$depth=@($path.Trim('\').Split('\')).Count}
        $row=[pscustomobject]@{Path=$path;SecuritySddl=$sddl;SecurityHash=(Get-WsmHashText $sddl);ExistingPolicy=[string]$entry.ExistingPolicy;Depth=$depth}
        $byPath[$key]=$row;$entries.Add($row)
    }
    foreach($entry in $entries){$ancestors=@(Get-WsmTaskSecurityFolderAncestors $entry.Path);foreach($ancestor in $ancestors){if($ancestor -ceq '\'){continue};if(-not $byPath.ContainsKey($ancestor.ToUpperInvariant())){throw ('Every target ancestor requires a reviewed security specification: '+$ancestor)}}}
    @($entries.ToArray() | Sort-Object Depth,Path)
}
function Get-WsmTaskSecurityDraftFields($Settings) {
    if($null -eq $Settings -or -not $Settings.PSObject.Properties['TaskSecurityCaptureStatus'] -or [string]$Settings.TaskSecurityCaptureStatus -cne 'Captured' -or -not $Settings.PSObject.Properties['TaskSecurityCapture']){return @{}}
    $capture=$Settings.TaskSecurityCapture
    if($null -eq $capture -or $capture.Kind -cne 'TaskSecurityCapture' -or $capture.SchemaVersion -ne 1 -or [string]$capture.TaskName -cne [string]$Settings.TaskName){return @{}}
    try{$expectedPath=ConvertTo-WsmTaskSecurityFolderPath ([string]$Settings.TaskPath) -AllowRoot;$capturedPath=ConvertTo-WsmTaskSecurityFolderPath ([string]$capture.TaskPath) -AllowRoot}catch{return @{}}
    if($capturedPath -cne $expectedPath -or [string]$capture.TaskFullPath -cne ($expectedPath+[string]$Settings.TaskName)){return @{}}
    $taskSddl=ConvertTo-WsmTaskSecuritySddl ([string]$capture.TaskSecuritySddl)
    if((Get-WsmHashText $taskSddl) -ine [string]$capture.TaskSecurityHash){return @{}}
    $folderSpecs=New-Object 'System.Collections.Generic.List[object]'
    foreach($folder in @($capture.Folders)){
        if($null -eq $folder -or -not $folder.PSObject.Properties['Path'] -or -not $folder.PSObject.Properties['SecuritySddl'] -or -not $folder.PSObject.Properties['SecurityHash']){return @{}}
        $path=ConvertTo-WsmTaskSecurityFolderPath ([string]$folder.Path) -AllowRoot;$canonical=ConvertTo-WsmTaskSecuritySddl ([string]$folder.SecuritySddl)
        if((Get-WsmHashText $canonical) -ine [string]$folder.SecurityHash){return @{}}
        $policy='CreateOnly';if($path -ceq '\'){$policy='VerifyExact'}
        $folderSpecs.Add([pscustomobject][ordered]@{Path=$path;SecuritySddl=$canonical;ExistingPolicy=$policy})
    }
    try{$validated=ConvertTo-WsmTaskSecurityFolderSpecs $folderSpecs.ToArray()}catch{return @{}}
    $expected=@(Get-WsmTaskSecurityFolderAncestors ([string]$Settings.TaskPath) | ForEach-Object {$_.ToUpperInvariant()} | Sort-Object)
    $actual=@($validated | ForEach-Object {$_.Path.ToUpperInvariant()} | Sort-Object)
    if(($expected -join '|') -cne ($actual -join '|')){return @{}}
    @{SecuritySddl=$taskSddl;FolderSecurity=@($folderSpecs.ToArray())}
}
function Test-WsmTaskSecurityNotFoundError($ErrorRecord) {
    $exception=$ErrorRecord.Exception
    while($exception){if([int]$exception.HResult -in @(-2147024894,-2147024893)){return $true};$exception=$exception.InnerException}
    $false
}
function Get-WsmTaskSecurityReceiptMap([object[]]$OwnedReceipts,[object[]]$Specs) {
    $specByPath=@{};foreach($spec in $Specs){$specByPath[$spec.Path.ToUpperInvariant()]=$spec}
    $receipts=@{}
    foreach($receipt in @($OwnedReceipts | Where-Object {$null -ne $_})){
        if(-not $receipt.PSObject.Properties['Path'] -or -not $receipt.PSObject.Properties['SecurityHash'] -or -not $receipt.PSObject.Properties['Kind'] -or -not $receipt.PSObject.Properties['OperationId'] -or $receipt.Kind -cne 'OwnedTaskFolder' -or [string]$receipt.OperationId -notmatch '^[a-fA-F0-9]{8}-(?:[a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}$' -or [string]$receipt.SecurityHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'Invalid owned Task Scheduler folder receipt.'}
        $path=ConvertTo-WsmTaskSecurityFolderPath ([string]$receipt.Path);$key=$path.ToUpperInvariant()
        if([string]$receipt.Path -cne $path -or -not $specByPath.ContainsKey($key) -or $receipt.SecurityHash -ine $specByPath[$key].SecurityHash){throw 'Owned Task Scheduler folder receipt does not bind an exact reviewed path and descriptor hash.'}
        if($receipts.ContainsKey($key)){throw 'Duplicate owned Task Scheduler folder receipt.'}
        $receipts[$key]=$receipt
    }
    $receipts
}
function Get-WsmTaskSecurityOwnershipReceipts($State) {
    $byPath=@{};$all=New-Object 'System.Collections.Generic.List[object]'
    foreach($record in @($State.Items)){if($record -and $record.PSObject.Properties['AuxiliaryOwnership']){foreach($receipt in @($record.AuxiliaryOwnership)){$key=(ConvertTo-WsmTaskSecurityFolderPath ([string]$receipt.Path)).ToUpperInvariant();if($byPath.ContainsKey($key)){if($byPath[$key].OperationId -cne $receipt.OperationId -or $byPath[$key].SecurityHash -ine $receipt.SecurityHash){throw 'Conflicting durable ownership receipts exist for one Task Scheduler folder.'}}else{$byPath[$key]=$receipt;$all.Add($receipt)}}}}
    foreach($pending in @($State.PendingOperations)){if($pending -and $pending.PSObject.Properties['AuxiliaryOwnership']){foreach($receipt in @($pending.AuxiliaryOwnership)){$key=(ConvertTo-WsmTaskSecurityFolderPath ([string]$receipt.Path)).ToUpperInvariant();if($byPath.ContainsKey($key)){if($byPath[$key].OperationId -cne $receipt.OperationId -or $byPath[$key].SecurityHash -ine $receipt.SecurityHash){throw 'Conflicting durable ownership receipts exist for one Task Scheduler folder.'}}else{$byPath[$key]=$receipt;$all.Add($receipt)}}}}
    $all.ToArray()
}
function Get-WsmTaskSecurityReceiptsForSpec($Spec,[object[]]$Receipts) {
    $folders=ConvertTo-WsmTaskSecurityFolderSpecs @($Spec.Desired.FolderSecurity);$allowed=@{};foreach($folder in $folders){$allowed[$folder.Path.ToUpperInvariant()]=$folder}
    $selected=New-Object 'System.Collections.Generic.List[object]'
    foreach($receipt in $Receipts){$path=ConvertTo-WsmTaskSecurityFolderPath ([string]$receipt.Path);$key=$path.ToUpperInvariant();if(-not $allowed.ContainsKey($key)){continue};if($receipt.Kind -cne 'OwnedTaskFolder' -or $receipt.SecurityHash -ine $allowed[$key].SecurityHash){throw 'Task folder receipt does not match the approved path/descriptor for this task.'};$selected.Add($receipt)}
    $selected.ToArray()
}
function Get-WsmTaskSecurityFolderObject($Scheduler,[string]$CanonicalPath) {
    if($CanonicalPath -ceq '\'){return $Scheduler.GetFolder('\')}
    $parent=$Scheduler.GetFolder('\')
    foreach($segment in $CanonicalPath.Trim('\').Split('\')){$parent=$parent.GetFolder($segment)}
    $parent
}
function Get-WsmTaskSecurityCollectionCount($Collection) { if($null -eq $Collection){return 0};if($Collection.PSObject.Properties['Count']){return [int]$Collection.Count};@($Collection).Count }
function Assert-WsmTaskSecurityFolders {
    [CmdletBinding()]param([Parameter(Mandatory)][object[]]$Folders,[object[]]$OwnedReceipts=@(),[object[]]$SharedReceipts=@(),$Scheduler)
    $specs=ConvertTo-WsmTaskSecurityFolderSpecs $Folders
    if(-not $Scheduler){$Scheduler=New-WsmTaskScheduler}
    $receipts=Get-WsmTaskSecurityReceiptMap (@($OwnedReceipts)+@($SharedReceipts)) $specs
    $results=New-Object 'System.Collections.Generic.List[object]'
    foreach($spec in $specs){
        if($spec.Path -ceq '\'){$folder=$Scheduler.GetFolder('\');$actual=ConvertTo-WsmTaskSecuritySddl ([string]$folder.GetSecurityDescriptor(7));$hash=Get-WsmHashText $actual;if($actual -cne $spec.SecuritySddl -or $hash -ine $spec.SecurityHash){throw 'Task Scheduler root folder security descriptor drifted.'};$results.Add([pscustomobject]@{Path=$spec.Path;SecuritySddl=$actual;SecurityHash=$hash;ExistingPolicy=$spec.ExistingPolicy;CreatedByThisOperation=$false});continue}
        try{$folder=Get-WsmTaskSecurityFolderObject $Scheduler $spec.Path}catch{if(Test-WsmTaskSecurityNotFoundError $_){throw ('Reviewed target Task Scheduler folder is absent: '+$spec.Path)};throw}
        if($spec.ExistingPolicy -ceq 'CreateOnly'){$key=$spec.Path.ToUpperInvariant();if(-not $receipts.ContainsKey($key) -or $receipts[$key].SecurityHash -ine $spec.SecurityHash){throw ('CreateOnly folder lacks matching durable ownership receipt: '+$spec.Path)}}
        $actual=ConvertTo-WsmTaskSecuritySddl ([string]$folder.GetSecurityDescriptor(7));$hash=Get-WsmHashText $actual
        if($actual -cne $spec.SecuritySddl -or $hash -ine $spec.SecurityHash){throw ('Task Scheduler folder security descriptor drifted: '+$spec.Path)}
        $results.Add([pscustomobject]@{Path=$spec.Path;SecuritySddl=$actual;SecurityHash=$hash;ExistingPolicy=$spec.ExistingPolicy;CreatedByThisOperation=($receipts.ContainsKey($spec.Path.ToUpperInvariant()))})
    }
    [pscustomobject]@{Passed=$true;Folders=$results.ToArray();OwnedReceipts=@($OwnedReceipts)}
}
function Prepare-WsmTaskSecurityFolders {
    [CmdletBinding()]param([Parameter(Mandatory)][object[]]$Folders,[Parameter(Mandatory)][scriptblock]$BeforeCreate,[scriptblock]$AfterCreate,[object[]]$OwnedReceipts=@(),[object[]]$SharedReceipts=@(),$Scheduler)
    $specs=ConvertTo-WsmTaskSecurityFolderSpecs $Folders
    if(-not $Scheduler){$Scheduler=New-WsmTaskScheduler}
    $receiptByPath=Get-WsmTaskSecurityReceiptMap (@($OwnedReceipts)+@($SharedReceipts)) $specs;$allReceipts=New-Object 'System.Collections.Generic.List[object]';foreach($receipt in $OwnedReceipts){$allReceipts.Add($receipt)}
    $results=New-Object 'System.Collections.Generic.List[object]'
    foreach($spec in $specs){
        if($spec.Path -ceq '\'){$folder=$Scheduler.GetFolder('\');$actual=ConvertTo-WsmTaskSecuritySddl ([string]$folder.GetSecurityDescriptor(7));$hash=Get-WsmHashText $actual;if($actual -cne $spec.SecuritySddl -or $hash -ine $spec.SecurityHash){throw 'Task Scheduler root folder security descriptor drifted; it will not be overwritten.'};$results.Add([pscustomobject]@{Path=$spec.Path;SecuritySddl=$actual;SecurityHash=$hash;ExistingPolicy=$spec.ExistingPolicy;CreatedByThisOperation=$false});continue}
        $parentPath='\';$parent=$Scheduler.GetFolder('\');$segments=@($spec.Path.Trim('\').Split('\'))
        for($index=0;$index -lt ($segments.Count-1);$index++){$parentPath=$parentPath+$segments[$index]+'\';$parent=$parent.GetFolder($segments[$index])}
        $name=$segments[$segments.Count-1];$existing=$null
        try{$existing=$parent.GetFolder($name)}catch{if(-not (Test-WsmTaskSecurityNotFoundError $_)){throw}}
        $key=$spec.Path.ToUpperInvariant();$owned=$receiptByPath.ContainsKey($key)
        if($existing){
            if($spec.ExistingPolicy -ceq 'CreateOnly' -and (-not $owned -or $receiptByPath[$key].SecurityHash -ine $spec.SecurityHash)){throw ('CreateOnly folder already exists without matching durable ownership: '+$spec.Path)}
            $actual=ConvertTo-WsmTaskSecuritySddl ([string]$existing.GetSecurityDescriptor(7));$hash=Get-WsmHashText $actual
            if($actual -cne $spec.SecuritySddl -or $hash -ine $spec.SecurityHash){throw ('Existing target folder ACL does not exactly match the reviewed descriptor; it will not be overwritten: '+$spec.Path)}
            $results.Add([pscustomobject]@{Path=$spec.Path;SecuritySddl=$actual;SecurityHash=$hash;ExistingPolicy=$spec.ExistingPolicy;CreatedByThisOperation=$owned});continue
        }
        if($owned){throw ('Owned Task Scheduler folder disappeared; preserve and reconcile its prior receipt: '+$spec.Path)}
        if(-not $BeforeCreate){throw 'A durable pre-create intent callback is required before creating a Task Scheduler folder.'}
        $operationId=[Guid]::NewGuid().ToString();$intent=[pscustomobject][ordered]@{Kind='TaskFolderCreateIntent';OperationId=$operationId;Path=$spec.Path;SecurityHash=$spec.SecurityHash;SecuritySddl=$spec.SecuritySddl;CreatedUtc=(Get-WsmUtc)}
        & $BeforeCreate $intent | Out-Null
        $created=$parent.CreateFolder($name,$spec.SecuritySddl)
        $verified=$parent.GetFolder($name);$actual=ConvertTo-WsmTaskSecuritySddl ([string]$verified.GetSecurityDescriptor(7));$hash=Get-WsmHashText $actual
        if($actual -cne $spec.SecuritySddl -or $hash -ine $spec.SecurityHash){throw ('Created target folder readback differs from reviewed security descriptor; retain intent and reconcile: '+$spec.Path+'; operation '+$operationId)}
        $receipt=[pscustomobject][ordered]@{Kind='OwnedTaskFolder';OperationId=$operationId;Path=$spec.Path;SecurityHash=$hash;CreatedUtc=(Get-WsmUtc)};if($AfterCreate){& $AfterCreate $receipt | Out-Null};$receiptByPath[$key]=$receipt;$allReceipts.Add($receipt)
        $results.Add([pscustomobject]@{Path=$spec.Path;SecuritySddl=$actual;SecurityHash=$hash;ExistingPolicy=$spec.ExistingPolicy;CreatedByThisOperation=$true})
    }
    [pscustomobject]@{Passed=$true;Folders=$results.ToArray();OwnedReceipts=$allReceipts.ToArray()}
}
function Test-WsmTaskSecurityFolderPreparation($Folders,[object[]]$OwnedReceipts=@(),[object[]]$SharedReceipts=@(),$Scheduler) {
    $specs=ConvertTo-WsmTaskSecurityFolderSpecs $Folders
    if(-not $Scheduler){$Scheduler=New-WsmTaskScheduler}
    $receipts=Get-WsmTaskSecurityReceiptMap (@($OwnedReceipts)+@($SharedReceipts)) $specs;$results=New-Object 'System.Collections.Generic.List[object]'
    foreach($spec in $specs){
        if($spec.Path -ceq '\'){$folder=$Scheduler.GetFolder('\');$actual=ConvertTo-WsmTaskSecuritySddl ([string]$folder.GetSecurityDescriptor(7));if($actual -cne $spec.SecuritySddl){throw 'Task Scheduler root folder security descriptor drifted.'};$results.Add([pscustomobject]@{Path=$spec.Path;Exists=$true;SecurityHash=$spec.SecurityHash;ExistingPolicy=$spec.ExistingPolicy});continue}
        $folder=$null;try{$folder=Get-WsmTaskSecurityFolderObject $Scheduler $spec.Path}catch{if(-not (Test-WsmTaskSecurityNotFoundError $_)){throw}}
        if($folder){$actual=ConvertTo-WsmTaskSecuritySddl ([string]$folder.GetSecurityDescriptor(7));if($actual -cne $spec.SecuritySddl){throw ('Existing target Task Scheduler folder ACL differs from reviewed descriptor: '+$spec.Path)};if($spec.ExistingPolicy -ceq 'CreateOnly' -and -not $receipts.ContainsKey($spec.Path.ToUpperInvariant())){throw ('Existing folder requires explicit VerifyExact review or a matching ownership receipt: '+$spec.Path)}}
        $results.Add([pscustomobject]@{Path=$spec.Path;Exists=($null -ne $folder);SecurityHash=$spec.SecurityHash;ExistingPolicy=$spec.ExistingPolicy})
    }
    [pscustomobject]@{Passed=$true;Folders=$results.ToArray()}
}
function Remove-WsmOwnedTaskFolders([object[]]$Folders,[object[]]$OwnedReceipts,[object[]]$SharedReceipts,[scriptblock]$BeforeDelete,[scriptblock]$AfterDelete,$Scheduler) {
    $specs=ConvertTo-WsmTaskSecurityFolderSpecs $Folders
    if(-not $Scheduler){$Scheduler=New-WsmTaskScheduler}
    $receipts=Get-WsmTaskSecurityReceiptMap (@($OwnedReceipts)+@($SharedReceipts)) $specs
    $removed=New-Object 'System.Collections.Generic.List[string]'
    foreach($spec in @($specs | Sort-Object @{Expression='Depth';Descending=$true},@{Expression='Path';Descending=$true})){
        $key=$spec.Path.ToUpperInvariant();if(-not $receipts.ContainsKey($key)){continue}
        $folder=$null;try{$folder=Get-WsmTaskSecurityFolderObject $Scheduler $spec.Path}catch{if(Test-WsmTaskSecurityNotFoundError $_){$removed.Add($spec.Path);continue};throw}
        $actual=ConvertTo-WsmTaskSecuritySddl ([string]$folder.GetSecurityDescriptor(7));if($actual -cne $spec.SecuritySddl -or (Get-WsmHashText $actual) -ine $receipts[$key].SecurityHash){throw ('Owned Task Scheduler folder security changed; will not delete: '+$spec.Path)}
        if((Get-WsmTaskSecurityCollectionCount ($folder.GetTasks(0))) -gt 0 -or (Get-WsmTaskSecurityCollectionCount ($folder.GetFolders(0))) -gt 0){continue}
        if(-not $BeforeDelete){throw 'Durable pre-delete intent callback is required before deleting an owned Task Scheduler folder.'}
        $deleteIntent=[pscustomobject][ordered]@{Kind='TaskFolderDeleteIntent';OperationId=[string]$receipts[$key].OperationId;Path=$spec.Path;SecurityHash=$spec.SecurityHash;Receipt=$receipts[$key];CreatedUtc=(Get-WsmUtc)}
        & $BeforeDelete $deleteIntent | Out-Null
        $parentPath='\';$parent=$Scheduler.GetFolder('\');$segments=@($spec.Path.Trim('\').Split('\'));for($index=0;$index -lt ($segments.Count-1);$index++){$parentPath=$parentPath+$segments[$index]+'\';$parent=$parent.GetFolder($segments[$index])}
        $parent.DeleteFolder($segments[$segments.Count-1],0);if($AfterDelete){& $AfterDelete $deleteIntent | Out-Null}
        $removed.Add($spec.Path)
    }
    $removed.ToArray()
}
function Capture-WsmTaskSecurity([string]$TaskPath,[string]$TaskName,$Scheduler) {
    $folderPath=ConvertTo-WsmTaskSecurityFolderPath $TaskPath -AllowRoot;$taskNameValue=ConvertTo-WsmTaskSecurityTaskName $TaskName
    if(-not $Scheduler){$Scheduler=New-WsmTaskScheduler}
    $folderPaths=@(Get-WsmTaskSecurityFolderAncestors $folderPath);$folderRows=New-Object 'System.Collections.Generic.List[object]'
    foreach($path in $folderPaths){$folder=Get-WsmTaskSecurityFolderObject $Scheduler $path;$sddl=ConvertTo-WsmTaskSecuritySddl ([string]$folder.GetSecurityDescriptor(7));$folderRows.Add([pscustomobject]@{Path=$path;SecuritySddl=$sddl;SecurityHash=(Get-WsmHashText $sddl)})}
    $taskFolder=Get-WsmTaskSecurityFolderObject $Scheduler $folderPath;$task=$taskFolder.GetTask($taskNameValue);$taskSddl=ConvertTo-WsmTaskSecuritySddl ([string]$task.GetSecurityDescriptor(7))
    [pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='TaskSecurityCapture';TaskPath=$folderPath;TaskName=$taskNameValue;TaskFullPath=($folderPath+$taskNameValue);TaskSecuritySddl=$taskSddl;TaskSecurityHash=(Get-WsmHashText $taskSddl);Folders=$folderRows.ToArray();CapturedUtc=(Get-WsmUtc);ProductionVerified=$false}
}
