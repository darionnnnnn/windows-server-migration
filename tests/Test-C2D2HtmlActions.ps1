#requires -Version 5.1
$ErrorActionPreference='Stop'
# B5: C2 software-disposition review and D2 source-candidate confirmation / workload-mapping HTML entry points.
# Covers the action map, roles, route policy, argument conversion, the real Source -> Manager D2 flow, the C2 batch submit, the closed view
# projection and the real console routes (real listener processes, real workers) for both the read and the write side.
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking -WarningAction SilentlyContinue
$script:checks=0
function Check([bool]$Condition,[string]$Message){$script:checks++;if(-not $Condition){throw $Message};Write-Output ('PASS '+$Message)}
function Reject([scriptblock]$Action,[string]$Message,[string]$Pattern=''){$script:checks++;$rejected=$false;$text='';try{& $Action|Out-Null}catch{$rejected=$true;$text=[string]$_.Exception.Message};if(-not $rejected){throw $Message};if($Pattern -and $text -notmatch $Pattern){throw ($Message+' (rejected with an unexpected message: '+$text+')')};Write-Output ('PASS '+$Message)}
function New-TestRoot([string]$Prefix){
    $id=[Convert]::ToBase64String([Guid]::NewGuid().ToByteArray()).TrimEnd('=').Replace('+','-').Replace('/','_')
    $path=Join-Path ([IO.Path]::GetTempPath()) ($Prefix+$id)
    if([IO.Directory]::Exists($path) -or [IO.File]::Exists($path)){throw 'Refusing to reuse a preexisting test root.'}
    [void][IO.Directory]::CreateDirectory($path);$path
}
function Remove-TestRoot([string]$Path,[string]$Prefix){
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\';$resolved=[IO.Path]::GetFullPath($Path);$name=[IO.Path]::GetFileName($resolved)
    if($name -notmatch ('^'+[regex]::Escape($Prefix)+'[A-Za-z0-9_-]{22}$') -or [IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ine $temp.TrimEnd('\')){throw 'Refusing to clean a test directory outside its newly-created random temp root.'}
    if([IO.Directory]::Exists($resolved)){if(([IO.File]::GetAttributes($resolved) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Refusing to clean a reparse-point test root.'};try{Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop}catch{Write-Warning ('Test cleanup could not remove '+$resolved)}}
}
# Mirrors what the console route does with a request body: bind Workspace/PairId, convert through ConvertTo-WsmHtmlArguments, then run the mapped command.
function Get-ActionArguments([string]$Action,$Body){& $module {param($a,$b) $map=Get-WsmHtmlActionMap;$command=Get-Command $map[$a] -CommandType Function;foreach($binding in @('Workspace','PairId')){if($command.Parameters.ContainsKey($binding) -and -not $b.PSObject.Properties[$binding]){throw ('test body is missing '+$binding)}};ConvertTo-WsmHtmlArguments $command $b} $Action $Body}
function Invoke-MappedAction([string]$Action,$Body){$arguments=Get-ActionArguments $Action $Body;& $module {param($a,$splat) $map=Get-WsmHtmlActionMap;& (Get-Command $map[$a] -CommandType Function) @splat} $Action $arguments}
function Get-SafeErrorCode([string]$Message){& $module {param($m) (Get-WsmHtmlSafeError $m).code} $Message}

$expected=[ordered]@{
    SourceCandidateList=@{Function='Get-WsmHtmlSourceCandidateList';Role='Source';Kind='view'}
    SourceCandidateConfirmExport=@{Function='Export-WsmSourceCandidateConfirmation';Role='Source';Kind='operation'}
    SourceCandidateConfirmImport=@{Function='Import-WsmSourceCandidateConfirmation';Role='Manager';Kind='operation'}
    SourceCandidateConfirmReview=@{Function='Get-WsmSourceCandidateConfirmationReview';Role='Manager';Kind='view'}
    SourceCandidateMappingReview=@{Function='Get-WsmSourceCandidateWorkloadMappingReview';Role='Manager';Kind='view'}
    SourceCandidateMappingSubmit=@{Function='Submit-WsmSourceCandidateWorkloadMappingReview';Role='Manager';Kind='operation'}
    SoftwareDispositionReview=@{Function='Get-WsmAssistiveSoftwareDispositionReview';Role='Manager';Kind='view'}
    SoftwareDispositionReviewSubmit=@{Function='Submit-WsmAssistiveSoftwareDispositionReview';Role='Manager';Kind='operation'}
}

# ---------------------------------------------------------------------------------------------------------------- 1. action map, roles, exports
$map=& $module {Get-WsmHtmlActionMap};$core=& $module {Get-WsmOperationActions}
foreach($name in $expected.Keys){
    $row=$expected[$name]
    Check ($map.Contains($name) -and [string]$map[$name] -ceq $row.Function) ('action '+$name+' resolves to '+$row.Function)
    Check ($module.ExportedFunctions.ContainsKey($row.Function)) ($row.Function+' is exported (worker runspaces and Test-ActionExports resolve it)')
    if($name -cne 'SourceCandidateList'){Check ($core.Contains($name) -and [string]$core[$name] -ceq $row.Function) ('action '+$name+' is in the durable operation table')}
    Check ((& $module {param($n) Get-WsmTextActionGroup $n} $name) -ceq $row.Role) ('action '+$name+' belongs to the '+$row.Role+' group')
}
foreach($role in @('Source','Manager','Target')){
    $metadata=@(& $module {param($r) Get-WsmHtmlActionMetadata -Role $r} $role)
    foreach($name in $expected.Keys){
        $entry=@($metadata|Where-Object action -CEQ $name)
        Check ($entry.Count -eq 1 -and $entry[0].requiredRole -ceq $expected[$name].Role -and $entry[0].roleAvailable -eq ($role -ceq $expected[$name].Role)) ($name+' is available to '+$expected[$name].Role+' only (seen from '+$role+')')
        Check ($entry[0].readOnly -eq ($expected[$name].Kind -ceq 'view')) ($name+' read-only flag matches its route kind')
    }
}
$submitMeta=@(& $module {Get-WsmHtmlActionMetadata -Role Manager})
foreach($name in @('SourceCandidateConfirmImport','SourceCandidateMappingSubmit','SoftwareDispositionReviewSubmit')){
    $entry=@($submitMeta|Where-Object action -CEQ $name)[0]
    Check (@($entry.parameters|Where-Object {$_.name -ceq 'ExpectedRevision' -and $_.required}).Count -eq 1) ($name+' exposes its mandatory ExpectedRevision CAS parameter')
}
$decisionsSchema=@(@($submitMeta|Where-Object action -CEQ 'SoftwareDispositionReviewSubmit')[0].parameters|Where-Object name -CEQ 'Decisions')[0].schema
Check ($decisionsSchema.title -ceq 'SoftwareDispositionBatch' -and $decisionsSchema.properties.Contains('Disposition')) 'generic form uses the software disposition batch row schema'
$mappingSchema=@(@($submitMeta|Where-Object action -CEQ 'SourceCandidateMappingSubmit')[0].parameters|Where-Object name -CEQ 'Decisions')[0].schema
Check ($mappingSchema.title -ceq 'WorkloadMappingDecisions' -and $mappingSchema.properties.Contains('ReferenceId')) 'generic form uses the workload mapping row schema'
Check ((& $module {param($m) (Get-WsmHtmlActionMetadata -Role Source|Where-Object action -CEQ 'SourceCandidateConfirmExport').parameters|ForEach-Object name} $null) -notcontains 'Jobs') 'the internal Jobs parameter is not exposed to the client'

# ---------------------------------------------------------------------------------------------------------------- 2. role / route / pair gate
$gate={param($a,$r,$p,$route) & $module {param($a,$r,$p,$route) Assert-WsmHtmlC2D2ActionAccess $a $r $p $route} $a $r $p $route}
foreach($name in $expected.Keys){
    $row=$expected[$name];$route=$(if($row.Kind -ceq 'view'){'/api/view'}else{'/api/operations'});$otherRoute=$(if($row.Kind -ceq 'view'){'/api/operations'}else{'/api/view'})
    $pair=$(if($row.Role -ceq 'Manager'){'pair-1'}else{''})
    & $gate $name $row.Role $pair $route
    foreach($wrong in @(@('Source','Manager','Target')|Where-Object {$_ -cne $row.Role})){Reject {& $gate $name $wrong 'pair-1' $route} ($name+' is refused for the '+$wrong+' role') 'Unsupported operation role'}
    Reject {& $gate $name $row.Role $pair $otherRoute} ($name+' is refused on the wrong endpoint') 'Unsupported operation route'
    if($row.Role -ceq 'Manager'){Reject {& $gate $name 'Manager' '' $route} ($name+' requires a selected Manager pair') 'requires a selected Manager pair'}
}
& $gate 'Inventory' 'Source' '' '/api/operations'
Check ((Get-SafeErrorCode 'Unsupported operation role: this action requires the Source role.') -ceq 'invalid_request') 'role and route refusals classify as invalid_request'

# ---------------------------------------------------------------------------------------------------------------- 3. argument conversion
$goodHash='a'*64
$workspaceProbe=Join-Path ([IO.Path]::GetTempPath()) 'b5-unused-workspace'
Reject {Get-ActionArguments 'SoftwareDispositionReviewSubmit' ([pscustomobject]@{Workspace=$workspaceProbe;PairId='p';ExpectedRevision=1;Ack=$true;Decisions=@([pscustomobject]@{SoftwareId='s'})})} 'a missing ExpectedPreviewHash is refused' 'Required parameter missing: ExpectedPreviewHash'
Reject {Get-ActionArguments 'SoftwareDispositionReviewSubmit' ([pscustomobject]@{Workspace=$workspaceProbe;PairId='p';ExpectedRevision=1;ExpectedPreviewHash=$goodHash;Decisions=@([pscustomobject]@{SoftwareId='s'})})} 'a missing Ack is refused' 'Required parameter missing: Ack'
Reject {Get-ActionArguments 'SoftwareDispositionReviewSubmit' ([pscustomobject]@{Workspace=$workspaceProbe;PairId='p';ExpectedRevision=1;ExpectedPreviewHash=$goodHash;Ack='true';Decisions=@([pscustomobject]@{SoftwareId='s'})})} 'a string Ack is not a JSON boolean' 'Boolean parameter'
Reject {Get-ActionArguments 'SoftwareDispositionReviewSubmit' ([pscustomobject]@{Workspace=$workspaceProbe;PairId='p';ExpectedRevision='1.5';ExpectedPreviewHash=$goodHash;Ack=$true;Decisions=@([pscustomobject]@{SoftwareId='s'})})} 'a fractional ExpectedRevision is refused' 'whole number'
Reject {Get-ActionArguments 'SourceCandidateMappingSubmit' ([pscustomobject]@{Workspace=$workspaceProbe;PairId='p';CandidateItemId='x';ExpectedInventoryHash=$goodHash;ExpectedConfirmationHash=$goodHash;ExpectedRevision=1})} 'a mapping submit without Decisions is refused' 'Required parameter missing: Decisions'
Reject {Get-ActionArguments 'SourceCandidateConfirmImport' ([pscustomobject]@{Workspace=$workspaceProbe;PairId='p';Path='x';ExpectedHash=$goodHash;TargetPath='y';Owner='o';Evidence='e'})} 'an import without ExpectedRevision is refused' 'Required parameter missing: ExpectedRevision'
Reject {Get-ActionArguments 'SourceCandidateConfirmImport' ([pscustomobject]@{Workspace=$workspaceProbe;PairId='p';Path='x';ExpectedHash=$goodHash;TargetPath='y';Evidence='e';ExpectedRevision=1})} 'an import without an owner is refused' 'Required parameter missing: Owner'
Reject {Get-ActionArguments 'SourceCandidateConfirmExport' ([pscustomobject]@{Workspace=$workspaceProbe;ScanId='s';CandidateId=$goodHash})} 'an export without the candidate hash is refused' 'Required parameter missing: ExpectedCandidateHash'
Reject {Get-ActionArguments 'SourceCandidateConfirmExport' ([pscustomobject]@{Workspace=$workspaceProbe;ScanId='s';CandidateId=$goodHash;ExpectedCandidateHash=$goodHash;Jobs=@()})} 'a client cannot inject the internal Jobs parameter' 'Internal operation parameter'
Reject {Get-ActionArguments 'SourceCandidateConfirmReview' ([pscustomobject]@{Workspace=$workspaceProbe;PairId='p';ItemId='i';Surprise=1})} 'an unknown parameter is refused' 'Unsupported operation parameter'
$convertedImport=Get-ActionArguments 'SourceCandidateConfirmImport' ([pscustomobject]@{Workspace=$workspaceProbe;PairId='p';Path='x';ExpectedHash=$goodHash;TargetPath='y';Owner='o';Evidence='e';ExpectedRevision=7})
Check ($convertedImport.ExpectedRevision -eq 7 -and $convertedImport.ExpectedHash -ceq $goodHash -and $convertedImport.Contains('Path')) 'a complete import body converts to typed arguments without altering the paths'

# ---------------------------------------------------------------------------------------------------------------- real console process helpers
function Start-ConsoleProcess([string]$Workspace,[string]$PairId,[string]$Role,[string]$Root,[string]$Name){
    $ready=Join-Path $Root ($Name+'-ready.json');$stop=Join-Path $Root ($Name+'-stop.flag')
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'Start-C2D2TestServer.ps1'),'-Workspace',$Workspace,'-Role',$Role,'-ReadyPath',$ready,'-StopFile',$stop);if($PairId){$arguments+=@('-PairId',$PairId)}
    $errorLog=Join-Path $Root ($Name+'-stderr.log');$outputLog=Join-Path $Root ($Name+'-stdout.log')
    $process=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardError $errorLog -RedirectStandardOutput $outputLog
    $deadline=[DateTime]::UtcNow.AddSeconds(90)
    while(-not [IO.File]::Exists($ready)){
        if($process.HasExited){$detail='';if([IO.File]::Exists($errorLog)){$detail=(Get-Content -LiteralPath $errorLog -Raw)};throw ('The '+$Name+' console process exited before it was ready. '+$detail)}
        if([DateTime]::UtcNow -gt $deadline){try{$process.Kill()}catch{};throw ('The '+$Name+' console process did not become ready.')}
        Start-Sleep -Milliseconds 200
    }
    Start-Sleep -Milliseconds 200
    $info=Get-Content -LiteralPath $ready -Raw|ConvertFrom-Json
    [pscustomobject]@{Process=$process;Url=[string]$info.Url;Stop=$stop;Name=$Name}
}
function Stop-ConsoleProcess($Console){
    if(-not $Console){return}
    try{[IO.File]::WriteAllText($Console.Stop,'stop')}catch{}
    if(-not $Console.Process.WaitForExit(20000)){try{$Console.Process.Kill()}catch{}}
}
function Invoke-Console($Console,[string]$Method,[string]$Path,$Body,[string]$Token){
    $headers=@{Accept='application/json'};if($Token){$headers['X-Wsm-Token']=$Token}
    $parameters=@{Uri=($Console.Url+$Path);Method=$Method;Headers=$headers;UseBasicParsing=$true;TimeoutSec=60}
    if($Method -ceq 'POST'){$headers['Origin']=$Console.Url;$parameters.ContentType='application/json';$parameters.Body=[Text.Encoding]::UTF8.GetBytes(($Body|ConvertTo-Json -Depth 30 -Compress))}
    try{$response=Invoke-WebRequest @parameters;$status=[int]$response.StatusCode;$text=[string]$response.Content}
    catch{
        if(-not $_.Exception.Response){throw}
        $status=[int]$_.Exception.Response.StatusCode;$errorStream=$_.Exception.Response.GetResponseStream();if($errorStream.CanSeek){$errorStream.Position=0};$reader=New-Object IO.StreamReader($errorStream,[Text.Encoding]::UTF8);$text=$reader.ReadToEnd();$reader.Dispose()
    }
    $parsed=$null;if($text){try{$parsed=$text|ConvertFrom-Json}catch{}}
    [pscustomobject]@{Status=$status;Body=$parsed;Text=$text}
}
function Get-ConsoleSession($Console){$session=Invoke-Console $Console GET '/api/session' $null '';if($session.Status -ne 200){throw 'Console session request failed.'};$session.Body}
function New-ConsoleRequest($Session,[string]$Action,$Arguments){
    [ordered]@{action=$Action;args=$Arguments;expectedRevision=[int]$Session.revision;expectedDecisionRevision=$Session.decisionRevision;expectedSelectionRevision=$Session.selectionRevision;expectedDataVersion=[string]$Session.dataVersion;contextId=[string]$Session.contextId}
}
function Wait-ConsoleJob($Console,[string]$Token,[string]$JobId){
    $deadline=[DateTime]::UtcNow.AddSeconds(120)
    while([DateTime]::UtcNow -lt $deadline){
        $reply=Invoke-Console $Console GET ('/api/jobs/'+$JobId) $null $Token
        if($reply.Status -eq 200){$job=$(if($reply.Body.PSObject.Properties['job']){$reply.Body.job}else{$reply.Body});if(@('Succeeded','Failed','Cancelled','Interrupted','Blocked','ReviewRequired') -contains [string]$job.status){return $job}}
        Start-Sleep -Milliseconds 300
    }
    throw 'The console job did not finish in time.'
}

# ---------------------------------------------------------------------------------------------------------------- 4. C2 software disposition (real catalog, batch, CAS, special product, real console)
$c2Prefix='b5c2-';$c2Root=New-TestRoot $c2Prefix;$c2Console=$null;$c2SourceRoleConsole=$null
try{
    $root=$c2Root
    $workspace=Join-Path $root 'manager';[void](Initialize-WsmWorkspace $workspace)
    $hostId=[Guid]::NewGuid().ToString();$source=[pscustomobject][ordered]@{HostId=$hostId;Fingerprint=('a'*64);Name='disposition-fixture';OS='Windows Server';Version='2025'}
    $consumer=New-WsmItem $hostId Services Service 'Selected consumer' 'selected-consumer' ([pscustomobject]@{PathName='D:\FixtureData\svc.exe'}) @() Success
    $unselected=New-WsmItem $hostId Services Service 'Unselected consumer' 'unselected-consumer' ([pscustomobject]@{PathName='D:\FixtureData\other.exe'}) @() Success
    $inventory=New-WsmInventory $source 1 @($consumer,$unselected)
    $catalogSource=[pscustomobject][ordered]@{HostId=$hostId;Fingerprint=$source.Fingerprint;Name=$source.Name;InventoryRevision=1;InventoryProjectionHash=(& $module {param($value) Get-WsmSoftwareInventoryProjectionHash $value} $inventory)}
    $capture=[pscustomobject][ordered]@{CapturedUtc=[DateTime]::UtcNow.ToString('o');CaptureIdentity='fixture-owner';AccountContext='System';CaptureHost='fixture-host';PowerShellVersion='5.1';RequestedPortableRoots=@('D:\FixtureData\PortableApp')}
    function New-SoftwareRow([string]$hex,[string]$name,[string]$scope,[string]$sid,[string]$location,[string]$sourceKind,[string[]]$itemIds,[string]$architecture='x64'){
        [pscustomobject][ordered]@{SoftwareId=('sw-'+$hex);Name=$name;Version='Unknown';Publisher='Fixture';Architecture=$architecture;Scope=$scope;SID=$sid;RegistryView='Registry64';Location=$location;SourceKind=$sourceKind;Evidence=$(if($sourceKind -ceq 'Registry'){[pscustomobject]@{RegistryPath='HKLM64\Uninstall\'+$hex;NaturalKey=$hex}}else{[pscustomobject]@{EvidenceKind='OwnerObserved'}});ObservedUtc=[DateTime]::UtcNow.ToString('o');CaptureStatus='Success';ItemIds=$itemIds;AccountContext='System'}
    }
    $rows=@(
        (New-SoftwareRow ('a'*32) 'Selected runtime' Machine '' 'D:\FixtureData\Apps\Selected' Registry @($consumer.ItemId)),
        (New-SoftwareRow ('b'*32) 'Unselected user tool' User 'S-1-5-21-100-200-300-1001' 'registry:HKU\fixture\Uninstall\tool' Registry @($unselected.ItemId) x86),
        (New-SoftwareRow ('c'*32) 'Microsoft SQL Server Database Engine' Machine '' 'D:\FixtureData\Sql' Registry @()),
        (New-SoftwareRow ('d'*32) 'Portable business tool' Portable '' 'D:\FixtureData\PortableApp\tool.exe' PortableEvidence @())
    )
    $coverage=@(
        [pscustomobject][ordered]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='Registry';Count=2;Budget=[pscustomobject]@{MaxEntries=5000;VisitedEntries=2;MaxMetadataBytes=1048576;MetadataBytes=2048};ErrorKind=$null;ObservedUtc=[DateTime]::UtcNow.ToString('o')},
        [pscustomobject][ordered]@{Probe='Uninstall';Scope='User';SID='S-1-5-21-100-200-300-1001';View='Registry32';Status='PermissionDenied';EvidenceKind='Registry';Count=0;Budget=[pscustomobject]@{MaxEntries=5000};ErrorKind='AccessDenied';ObservedUtc=[DateTime]::UtcNow.ToString('o')}
    )
    $software=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='SoftwareCatalog';Source=$catalogSource;CaptureContext=$capture;Entries=$rows;Coverage=$coverage;PreparationRequirements=@(foreach($row in $rows){[pscustomobject][ordered]@{PreparationId=('prep-'+$row.SoftwareId.Substring(3));SoftwareId=$row.SoftwareId;Status='NeedsOwnerReview';RequiredPhase='PreparationReady';EvidenceStatus=$row.CaptureStatus;ConsumerItemIds=@($row.ItemIds);Owner='';Reason='Fixture discovery evidence'}});CatalogProjectionHash=''}
    $software.CatalogProjectionHash=& $module {param($value) Get-WsmSoftwareCatalogProjectionHash $value} $software
    $inventory | Add-Member NoteProperty SoftwareCatalog $software
    $inventoryPath=Join-Path $root 'source-inventory.json';& $module {param($path,$value) Write-WsmJson $path $value} $inventoryPath $inventory | Out-Null
    $inventoryHash=(Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $catalog=Import-WsmInventory -Workspace $workspace -Path $inventoryPath -ExpectedHash $inventoryHash -TargetName 'fixture-target'
    $catalog=Set-WsmGeneralHostMode $workspace $catalog.PairId $catalog.DecisionRevision
    $catalog=Set-WsmDecision -Workspace $workspace -PairId $catalog.PairId -ItemId @($consumer.ItemId) -Decision Include -ExpectedRevision $catalog.DecisionRevision
    $pairId=[string]$catalog.PairId
    $review=Invoke-MappedAction 'SoftwareDispositionReview' ([pscustomobject]@{Workspace=$workspace;PairId=$pairId})
    Check ($review.Kind -ceq 'AssistiveSoftwareDispositionReview' -and @($review.Rows).Count -eq 4 -and $review.PreviewHash -match '^[a-f0-9]{64}$') 'the registered review action returns every software row with a preview hash'
    $undecided=@($review.Rows|Where-Object {$_.DecisionState -cne 'Reviewed'})
    Check ($undecided.Count -eq 4 -and @($review.Rows|Where-Object SpecialProduct).Count -eq 1) 'the projection carries DecisionState per row and no workload-completeness field (the UI only lists undecided rows)'
    $special=@($review.Rows|Where-Object SpecialProduct)[0];$normal=@($review.Rows|Where-Object {-not $_.SpecialProduct})[0]
    $newDecisions={param($rows,$kind) @($rows|ForEach-Object {[pscustomobject]@{SoftwareId=$_.SoftwareId;Disposition=$kind;Owner='app owner';Reason='batch reason';Evidence='change:b5'}})}
    $body={param($rev,$hash,$ack,$decisions) [pscustomobject]@{Workspace=$workspace;PairId=$pairId;ExpectedRevision=$rev;ExpectedPreviewHash=$hash;Ack=$ack;Decisions=$decisions}}
    Reject {Invoke-MappedAction 'SoftwareDispositionReviewSubmit' (& $body $review.DecisionRevision $review.PreviewHash $true (& $newDecisions @($special) 'Reinstall'))} 'a special product cannot be submitted as Reinstall (the backend refuses even when the UI limit is removed)' 'not allowed'
    Reject {Invoke-MappedAction 'SoftwareDispositionReviewSubmit' (& $body $review.DecisionRevision $review.PreviewHash $false (& $newDecisions @($normal) 'External'))} 'a submit without the acknowledgement is refused' 'requires -Ack'
    Reject {Invoke-MappedAction 'SoftwareDispositionReviewSubmit' (& $body $review.DecisionRevision ('0'*64) $true (& $newDecisions @($normal) 'External'))} 'a stale preview hash is refused' 'changed'
    Reject {Invoke-MappedAction 'SoftwareDispositionReviewSubmit' (& $body ($review.DecisionRevision-1) $review.PreviewHash $true (& $newDecisions @($normal) 'External'))} 'a stale revision is refused' 'changed'
    Check ((Get-SafeErrorCode 'Software disposition review changed; obtain a new preview.') -ceq 'stale_context') 'a stale preview classifies as stale_context (409 class) for the UI'
    Check ((Get-WsmCatalog $workspace $pairId).DecisionRevision -eq $review.DecisionRevision) 'refused submits leave the revision untouched'
    $batch=@(@(& $newDecisions @($special) 'NotNeeded')+@(& $newDecisions @($review.Rows|Where-Object {$_.SoftwareId -cne $special.SoftwareId}|Select-Object -First 2) 'External'))
    $applied=Invoke-MappedAction 'SoftwareDispositionReviewSubmit' (& $body $review.DecisionRevision $review.PreviewHash $true $batch)
    Check ($applied.Status -ceq 'Applied' -and $applied.SubmittedCount -eq 3 -and $applied.DecisionRevision -gt $review.DecisionRevision) 'a batch submit applies and the revision advances'
    Check (@($applied.ReopenedReview.Rows|Where-Object {$_.DecisionState -ceq 'Reviewed'}).Count -eq 3 -and @($applied.ReopenedReview.Rows|Where-Object {$_.DecisionState -ceq 'Unreviewed'}).Count -eq 1) 'the reopened review shows the three decided rows and the one still undecided'
    Reject {Invoke-MappedAction 'SoftwareDispositionReviewSubmit' (& $body $review.DecisionRevision $review.PreviewHash $true (& $newDecisions @($normal) 'External'))} 'replaying the old preview after the batch is refused' 'changed'
    $viewed=& $module {param($r,$rev) ConvertTo-WsmHtmlC2D2View $r 'SoftwareDispositionReview' $rev} $applied.ReopenedReview 5
    Check (@($viewed.Rows).Count -eq 4 -and $viewed.PreviewHash -ceq $applied.ReopenedReview.PreviewHash -and @($viewed.Rows|Where-Object SpecialProduct).Count -eq 1 -and (@($viewed.Rows|Where-Object SpecialProduct)[0].AllowedDispositions -join ',') -ceq 'External,NotNeeded') 'the closed projection keeps preview hash, per-row state and the special product limit'
    Check (@($viewed.Coverage).Count -eq 2 -and $viewed.Coverage[1].Status -ceq 'PermissionDenied' -and $viewed.TrustedSoftwareRoots.Status -ceq 'Partial') 'the closed projection keeps coverage gaps visible'

    # real console: read through /api/view, write through /api/operations, stale -> 409
    $c2Console=Start-ConsoleProcess $workspace $pairId 'Manager' $c2Root 'c2'
    $session=Get-ConsoleSession $c2Console;$token=[string]$session.token
    $read=Invoke-Console $c2Console POST '/api/view' (New-ConsoleRequest $session 'SoftwareDispositionReview' @{}) $token
    Check ($read.Status -eq 200 -and @($read.Body.Rows).Count -eq 4 -and $read.Body.PreviewHash -match '^[a-f0-9]{64}$' -and $read.Body.DecisionRevision -eq $session.decisionRevision) 'the console serves the review through /api/view with its real preview hash and revision'
    Check (-not ($read.Text -match 'MigrationSpec|Desired|SettingsHash')) 'the served projection is closed (no raw specs or setting hashes)'
    $asOperation=Invoke-Console $c2Console POST '/api/operations' (New-ConsoleRequest $session 'SoftwareDispositionReview' @{}) $token
    Check ($asOperation.Status -eq 400) 'a read-only action posted to /api/operations is refused'
    $submitArguments=@{ExpectedRevision=[int]$read.Body.DecisionRevision;ExpectedPreviewHash=[string]$read.Body.PreviewHash;Ack=$true;Decisions=@(@{SoftwareId=[string]$normal.SoftwareId;Disposition='Reinstall';Owner='o';Reason='r';Evidence='e'})}
    $operation=New-ConsoleRequest $session 'SoftwareDispositionReviewSubmit' $submitArguments;$operation.operationId=[Guid]::NewGuid().ToString('D');$operation.idempotencyKey=[Guid]::NewGuid().ToString('D')
    $accepted=Invoke-Console $c2Console POST '/api/operations' $operation $token
    Check ($accepted.Status -eq 202) 'the console accepts a software disposition submit as a durable operation'
    $finished=Wait-ConsoleJob $c2Console $token ([string]$operation.operationId)
    Check ($finished.status -ceq 'Succeeded' -and $finished.action -ceq 'SoftwareDispositionReviewSubmit') 'the worker applied the submit and the job is durable'
    $afterRevision=(Get-WsmCatalog $workspace $pairId).DecisionRevision
    Check ($afterRevision -gt $review.DecisionRevision -and $afterRevision -gt $applied.DecisionRevision) 'the console submit advanced the decision revision again'
    $staleOperation=New-ConsoleRequest $session 'SoftwareDispositionReviewSubmit' $submitArguments;$staleOperation.operationId=[Guid]::NewGuid().ToString('D');$staleOperation.idempotencyKey=[Guid]::NewGuid().ToString('D')
    $stale=Invoke-Console $c2Console POST '/api/operations' $staleOperation $token
    Check ($stale.Status -eq 409 -and $stale.Body.code -ceq 'stale_revision') ('the same request against a changed catalog is refused with 409 stale_revision before any worker starts (seen '+$stale.Status+' '+$stale.Text+')')
    $fresh=Get-ConsoleSession $c2Console
    $badHash=New-ConsoleRequest $fresh 'SoftwareDispositionReviewSubmit' @{ExpectedRevision=[int]$fresh.decisionRevision;ExpectedPreviewHash=('0'*64);Ack=$true;Decisions=@(@{SoftwareId=[string]$normal.SoftwareId;Disposition='External';Owner='o';Reason='r';Evidence='e'})};$badHash.operationId=[Guid]::NewGuid().ToString('D');$badHash.idempotencyKey=[Guid]::NewGuid().ToString('D')
    $badAccepted=Invoke-Console $c2Console POST '/api/operations' $badHash $token
    $badJob=Wait-ConsoleJob $c2Console $token ([string]$badHash.operationId)
    Check ($badAccepted.Status -eq 202 -and $badJob.status -ceq 'Failed' -and $badJob.error.code -ceq 'stale_context') 'a wrong preview hash fails the durable job with the stale_context code (no write)'
    Check ((Get-WsmCatalog $workspace $pairId).DecisionRevision -eq $fresh.decisionRevision) 'the failed stale-hash job did not change the catalog'
    $c2SourceRoleConsole=Start-ConsoleProcess $workspace $pairId 'Source' $c2Root 'c2-source'
    $sourceSession=Get-ConsoleSession $c2SourceRoleConsole
    $wrongRole=Invoke-Console $c2SourceRoleConsole POST '/api/view' (New-ConsoleRequest $sourceSession 'SoftwareDispositionReview' @{}) ([string]$sourceSession.token)
    Check ($wrongRole.Status -eq 400 -and $wrongRole.Body.code -ceq 'invalid_request') 'a Source-role console refuses the Manager software review action'
}finally{
    Stop-ConsoleProcess $c2SourceRoleConsole;Stop-ConsoleProcess $c2Console
    Remove-TestRoot $c2Root $c2Prefix
}

# ---------------------------------------------------------------------------------------------------------------- 5. D2 Source scan -> export -> Manager import -> review -> mapping (real flow, real console)
$d2Prefix='b5d2-';$root=New-TestRoot $d2Prefix;$d2Manager=$null;$d2Source=$null;$d2SourceAsManager=$null
try{
    $sourceWorkspace=Join-Path $root 's';$managerWorkspace=Join-Path $root 'm';$fixtureC=Join-Path $root 'C-volume-fixture';$business=Join-Path $fixtureC 'Business';[void][IO.Directory]::CreateDirectory($business);[void][IO.Directory]::CreateDirectory((Join-Path $business 'EmptyDir'))
    $commandPath=Join-Path $business 'worker.exe';$argumentPath=Join-Path $business 'settings.json';[IO.File]::WriteAllText($commandPath,'worker fixture bytes');[IO.File]::WriteAllText($argumentPath,'settings fixture bytes')
    [void](Initialize-WsmOutputWorkspace -WorkRoot $sourceWorkspace -Role Source);[void](Initialize-WsmWorkspace $managerWorkspace)
    $sourceProfile=& $module {param($w) Read-WsmOutputProfile $w} $sourceWorkspace
    $source=[pscustomobject][ordered]@{HostId=[string]$sourceProfile.HostId;Fingerprint=([string]$sourceProfile.Fingerprint).ToLowerInvariant();Name='mapping-source-fixture';OS='Windows Server';Version='2025';Build='Unknown';Edition='Unknown';InstallationType='Unknown';Architecture='Unknown'}
    $volume=@(Get-CimInstance -ClassName Win32_Volume -ErrorAction Stop|Where-Object {([string]$_.DriveLetter).TrimEnd('\') -ieq 'C:'});if($volume.Count -ne 1){throw 'Fixture requires local C: volume identity for package capture.'}
    $volumeItem=& $module {param($h,$device) New-WsmItem $h Storage Volume 'C: fixture volume' 'volume:C:' @{DriveLetter='C:';DeviceID=[string]$device} @() Success 'Manual'} $source.HostId $volume[0].DeviceID
    $xml='<Task><Principals><Principal><UserId>S-1-5-18</UserId></Principal></Principals><Settings><Enabled>true</Enabled></Settings><Actions><Exec><Command>'+[Security.SecurityElement]::Escape($commandPath)+'</Command><Arguments>--config "'+[Security.SecurityElement]::Escape($argumentPath)+'" --token workload-canary-value</Arguments><WorkingDirectory>'+[Security.SecurityElement]::Escape($business)+'</WorkingDirectory></Exec></Actions></Task>'
    $taskSecurity=& $module {param($sddl) $folders=@(Get-WsmTaskSecurityFolderAncestors '\Fixture\'|ForEach-Object {[pscustomobject]@{Path=$_;SecuritySddl=$sddl;SecurityHash=(Get-WsmHashText $sddl)}});[pscustomobject]@{TaskSecurityCapture=[pscustomobject]@{Kind='TaskSecurityCapture';SchemaVersion=1;TaskName='Mapping';TaskPath='\Fixture\';TaskFullPath='\Fixture\Mapping';TaskSecuritySddl=$sddl;TaskSecurityHash=(Get-WsmHashText $sddl);Folders=$folders};TaskSecurityCaptureStatus='Captured'}} 'O:SYG:SYD:(A;;FA;;;SY)'
    $task=& $module {param($h,$x,$security) $settings=@{TaskName='Mapping';TaskPath='\Fixture\';Xml=$x;ObservedRuntime=[pscustomobject]@{State='NotObserved';Evidence='Fixture'};TaskSecurityCapture=$security.TaskSecurityCapture;TaskSecurityCaptureStatus=$security.TaskSecurityCaptureStatus};New-WsmItem $h Tasks ScheduledTask 'Mapping fixture task' '\Fixture\Mapping' $settings @() Success 'Manual'} $source.HostId $xml $taskSecurity
    $inventory=& $module {param($s,$items) New-WsmInventory $s 1 $items} $source @($volumeItem,$task)
    & $module {param($i) $catalog=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='SoftwareCatalog';Source=[pscustomobject][ordered]@{HostId=$i.Source.HostId;Fingerprint=$i.Source.Fingerprint;Name=$i.Source.Name;InventoryRevision=[int]$i.Revision;InventoryProjectionHash=(Get-WsmSoftwareInventoryProjectionHash $i)};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=(Get-WsmUtc);CaptureIdentity='Fixture';AccountContext='Unknown';CaptureHost='Fixture';PowerShellVersion=$PSVersionTable.PSVersion.ToString();RequestedPortableRoots=@()};Entries=@();Coverage=@([pscustomobject][ordered]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='NotTested';EvidenceKind='Fixture';Count=0;Budget=[pscustomobject]@{MaxEntries=0};ErrorKind='FixtureNotTested';ObservedUtc=(Get-WsmUtc)});PreparationRequirements=@();CatalogProjectionHash=('0'*64)};$catalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $catalog;Assert-WsmSoftwareCatalog $catalog -SourceInventory $i|Out-Null;$i|Add-Member NoteProperty SoftwareCatalog $catalog -Force} $inventory
    $inventory|Add-Member NoteProperty WorkloadDiscovery (& $module {param($i) Get-WsmWorkloadDiscovery $i} $inventory) -Force
    $inventoryPath=Join-Path (Join-Path (Join-Path (Join-Path $sourceWorkspace 'hosts') $sourceProfile.Fingerprint) 'inventory') 'inventory-1.json';& $module {param($p,$i) Write-WsmJson $p $i} $inventoryPath $inventory
    $inventoryHash=(Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $sourceSnapshotPath=Join-Path $sourceWorkspace ('assistive/snapshots/'+$inventoryHash+'.json');[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($sourceSnapshotPath));[IO.File]::Copy($inventoryPath,$sourceSnapshotPath,$false)
    $jobId=[Guid]::NewGuid().ToString('D');$job=[pscustomobject]@{jobId=$jobId;action='SourceInventory';role='Source';workspace=$sourceWorkspace;status='Succeeded';outputs=@([pscustomobject]@{Path=$inventoryPath;SHA256=$inventoryHash})}
    $null=Set-WsmWizardInventoryBinding -Workspace $sourceWorkspace -Role Source -JobId $jobId -ExpectedWizardRevision 0 -Jobs @($job)
    & $module {param($fixture) $script:WsmSourceCandidateTestRoot=$fixture;Set-Item Function:\Get-WsmSourceCandidateRoot -Value {param([string]$Workspace,$Profile)$script:WsmSourceCandidateTestRoot}} $fixtureC
    $scan=Invoke-WsmSourceCandidateScan -Workspace $sourceWorkspace -Jobs @($job);$artifact=Get-Content -LiteralPath $scan.CandidatePath -Raw|ConvertFrom-Json
    $candidate=@($artifact.Candidates|Where-Object {$_.CandidateType -ceq 'DirectoryRoot' -and $_.Path -ieq $business})[0];if(-not $candidate){throw 'Fixture source scan did not discover the workload data directory.'}
    $catalog=Import-WsmInventory -Workspace $managerWorkspace -Path $inventoryPath -ExpectedHash $inventoryHash -TargetName 'mapping-target'
    $catalog=Enable-WsmAssistiveMode -Workspace $managerWorkspace -PairId $catalog.PairId -ExpectedRevision $catalog.DecisionRevision
    $catalog=Set-WsmAssistiveSelections -Workspace $managerWorkspace -PairId $catalog.PairId -ExpectedRevision $catalog.Assistive.Revision -ItemIds @([string]$volumeItem.ItemId) -Selected $false -Reason 'Fixture volume identity only.'
    $pairId=[string]$catalog.PairId
    # Source side through the registered actions
    $list=Invoke-MappedAction 'SourceCandidateList' ([pscustomobject]@{Workspace=$sourceWorkspace;ScanId=[string]$scan.ScanId})
    Check ($list.CandidateHash -ceq $scan.CandidateHash -and @($list.Candidates|Where-Object {$_.CandidateId -ceq $candidate.CandidateId -and $_.Path -ieq $business}).Count -eq 1) 'the candidate list action returns the scan artifact hash and the chosen candidate'
    Reject {Invoke-MappedAction 'SourceCandidateList' ([pscustomobject]@{Workspace=$managerWorkspace;ScanId=[string]$scan.ScanId})} 'the candidate list refuses a non-Source workspace' 'Source workspace'
    Reject {Invoke-MappedAction 'SourceCandidateList' ([pscustomobject]@{Workspace=$sourceWorkspace;ScanId='..\..\x'})} 'the candidate list refuses a traversal-shaped ScanId'
    $exportArguments=Get-ActionArguments 'SourceCandidateConfirmExport' ([pscustomobject]@{Workspace=$sourceWorkspace;ScanId=[string]$scan.ScanId;ExpectedCandidateHash=[string]$scan.CandidateHash;CandidateId=[string]$candidate.CandidateId})
    Reject {& $module {param($splat,$jobs) $splat.Jobs=@($jobs);Export-WsmSourceCandidateConfirmation @splat} @{Workspace=$managerWorkspace;ScanId=[string]$scan.ScanId;ExpectedCandidateHash=[string]$scan.CandidateHash;CandidateId=[string]$candidate.CandidateId} @($job)} 'export function refuses a Manager workspace by its own role check' 'enrolled Source workspace'
    Reject {$wrong=@{}+$exportArguments;$wrong.ExpectedCandidateHash=('0'*64);$wrong.Jobs=@($job);& $module {param($splat) Export-WsmSourceCandidateConfirmation @splat} $wrong} 'export refuses a stale candidate artifact hash'
    $exported=& $module {param($splat) Export-WsmSourceCandidateConfirmation @splat} (@{}+$exportArguments+@{Jobs=@($job)})
    Check ($exported.Status -ceq 'Confirmed' -and $exported.ConfirmationHash -match '^[a-f0-9]{64}$' -and $exported.MemberCount -ge 3) 'the registered export action produces the immutable confirmation (files plus the empty directory)'
    # Manager side
    $importBody={param($rev,$hash,$target) [pscustomobject]@{Workspace=$managerWorkspace;PairId=$pairId;Path=$exported.ConfirmationPath;ExpectedHash=$hash;TargetPath=$target;Owner='fixture owner';Evidence='change:b5';ExpectedRevision=$rev}}
    $catalog=Get-WsmCatalog $managerWorkspace $pairId
    Reject {Invoke-MappedAction 'SourceCandidateConfirmImport' (& $importBody ($catalog.DecisionRevision-1) $exported.ConfirmationHash $business)} 'import refuses a stale Manager revision' 'changed'
    Reject {Invoke-MappedAction 'SourceCandidateConfirmImport' (& $importBody $catalog.DecisionRevision $exported.ConfirmationHash (Join-Path $fixtureC 'Elsewhere'))} 'import refuses a remapped target path' 'cannot remap'
    Reject {Invoke-MappedAction 'SourceCandidateConfirmImport' (& $importBody $catalog.DecisionRevision ('1'*64) $business)} 'import refuses a wrong independently supplied hash'
    Check ((Get-SafeErrorCode 'Manager review changed; refresh the confirmation review before import.') -ceq 'stale_context') 'a stale import classifies as stale_context (409 class)'
    $imported=Invoke-MappedAction 'SourceCandidateConfirmImport' (& $importBody $catalog.DecisionRevision $exported.ConfirmationHash $business)
    Check ($imported.Status -ceq 'ImportedReviewRequired' -and $imported.ItemId -match '^[a-f0-9]{64}$' -and $imported.DecisionRevision -gt $catalog.DecisionRevision) 'the registered import action creates the pending item and advances the revision'
    $confirmation=Invoke-MappedAction 'SourceCandidateConfirmReview' ([pscustomobject]@{Workspace=$managerWorkspace;PairId=$pairId;ItemId=$imported.ItemId})
    $confirmationView=& $module {param($r,$rev) ConvertTo-WsmHtmlC2D2View $r 'SourceCandidateConfirmReview' $rev} $confirmation 4
    $directoryMembers=@($confirmation.Members|Where-Object {$_.PSObject.Properties['EntryType'] -and $_.EntryType -ceq 'Directory'})
    Check ($directoryMembers.Count -ge 1 -and $confirmationView.DirectoryMemberCount -eq $directoryMembers.Count -and $confirmationView.FileMemberCount -eq ($confirmation.MemberCount-$directoryMembers.Count) -and $confirmationView.MemberCount -eq $confirmation.MemberCount) 'the closed confirmation view counts files and empty directories separately'
    Check (@($confirmationView.Members|Where-Object {$_.EntryType -ceq 'Directory'}).Count -eq $directoryMembers.Count -and $confirmationView.ConfirmationHash -ceq $exported.ConfirmationHash -and -not $confirmationView.MembersTruncated) 'directory members keep their EntryType and the confirmation hash survives projection'
    $catalog=Get-WsmCatalog $managerWorkspace $pairId
    $catalog=Set-WsmDecision -Workspace $managerWorkspace -PairId $pairId -ItemId @($imported.ItemId) -Decision Include -ExpectedRevision $catalog.DecisionRevision
    $catalog=Get-WsmCatalog $managerWorkspace $pairId
    $catalog=Set-WsmDecision -Workspace $managerWorkspace -PairId $pairId -ItemId @($task.ItemId) -Decision Include -ExpectedRevision $catalog.DecisionRevision
    $mappingReview=Invoke-MappedAction 'SourceCandidateMappingReview' ([pscustomobject]@{Workspace=$managerWorkspace;PairId=$pairId;CandidateItemId=$imported.ItemId})
    Check (@($mappingReview.References).Count -ge 3 -and $mappingReview.ConfirmationHash -ceq $exported.ConfirmationHash -and $mappingReview.InventoryHash -ceq $inventoryHash) 'the registered mapping review returns every workload reference with the hashes the submit must echo'
    $mappingView=& $module {param($r,$rev) ConvertTo-WsmHtmlC2D2View $r 'SourceCandidateMappingReview' $rev} $mappingReview 4
    Check (@($mappingView.References).Count -eq @($mappingReview.References).Count -and @($mappingView.References|Where-Object {$_.ReferenceId -match '^[a-f0-9]{64}$' -and $_.ReferenceKind}).Count -eq @($mappingReview.References).Count -and $mappingView.DecisionRevision -eq $mappingReview.DecisionRevision) 'the closed mapping view keeps reference identities, kinds and the decision revision'
    $mappingDecisions={param($rows) @($rows|ForEach-Object {if($_.ReferenceKind -ceq 'TaskCommand'){[pscustomobject]@{ReferenceId=$_.ReferenceId;Decision='Include';FileScopeItemId=[string]$imported.ItemId;DependencyType='Mandatory'}}else{[pscustomobject]@{ReferenceId=$_.ReferenceId;Decision='Manual';FileScopeItemId='';DependencyType='None'}}})}
    $submitBody={param($inv,$conf,$rev,$decisions) [pscustomobject]@{Workspace=$managerWorkspace;PairId=$pairId;CandidateItemId=[string]$imported.ItemId;ExpectedInventoryHash=$inv;ExpectedConfirmationHash=$conf;ExpectedRevision=$rev;Decisions=$decisions}}
    $goodDecisions=& $mappingDecisions $mappingReview.References
    Reject {Invoke-MappedAction 'SourceCandidateMappingSubmit' (& $submitBody ('0'*64) $mappingReview.ConfirmationHash $mappingReview.DecisionRevision $goodDecisions)} 'a stale inventory hash is refused' 'another source inventory'
    Reject {Invoke-MappedAction 'SourceCandidateMappingSubmit' (& $submitBody $mappingReview.InventoryHash ('0'*64) $mappingReview.DecisionRevision $goodDecisions)} 'a stale confirmation hash is refused' 'another candidate confirmation'
    Reject {Invoke-MappedAction 'SourceCandidateMappingSubmit' (& $submitBody $mappingReview.InventoryHash $mappingReview.ConfirmationHash ($mappingReview.DecisionRevision-1) $goodDecisions)} 'a stale decision revision is refused' 'review changed'
    Reject {Invoke-MappedAction 'SourceCandidateMappingSubmit' (& $submitBody $mappingReview.InventoryHash $mappingReview.ConfirmationHash $mappingReview.DecisionRevision @($goodDecisions|Select-Object -First 1))} 'an incomplete set of per-reference decisions is refused' 'every source workload reference'
    foreach($message in @('Workload mapping is bound to another source inventory.','Workload mapping is bound to another candidate confirmation.','Manager review changed; refresh workload mapping before submitting.')){Check ((Get-SafeErrorCode $message) -ceq 'stale_context') ('safe error classifies as stale_context: '+$message)}
    Check ((Get-WsmCatalog $managerWorkspace $pairId).DecisionRevision -eq $mappingReview.DecisionRevision) 'refused mapping submits leave the revision untouched'
    # real console: view projection, route/role gates, durable write and 409
    $d2Manager=Start-ConsoleProcess $managerWorkspace $pairId 'Manager' $root 'd2-manager'
    $session=Get-ConsoleSession $d2Manager;$token=[string]$session.token
    $confirmRead=Invoke-Console $d2Manager POST '/api/view' (New-ConsoleRequest $session 'SourceCandidateConfirmReview' @{ItemId=[string]$imported.ItemId}) $token
    Check ($confirmRead.Status -eq 200 -and $confirmRead.Body.DirectoryMemberCount -ge 1 -and $confirmRead.Body.ConfirmationHash -ceq $exported.ConfirmationHash -and @($confirmRead.Body.Members).Count -eq $confirmation.MemberCount) 'the console serves the confirmation review with directory members and hashes'
    $mappingRead=Invoke-Console $d2Manager POST '/api/view' (New-ConsoleRequest $session 'SourceCandidateMappingReview' @{CandidateItemId=[string]$imported.ItemId}) $token
    Check ($mappingRead.Status -eq 200 -and @($mappingRead.Body.References).Count -eq @($mappingReview.References).Count -and $mappingRead.Body.DecisionRevision -eq $session.decisionRevision) 'the console serves the mapping review through /api/view'
    $wrongWorkspace=Invoke-Console $d2Manager POST '/api/view' (New-ConsoleRequest $session 'SourceCandidateMappingReview' @{CandidateItemId=[string]$imported.ItemId;Workspace=(Join-Path ([IO.Path]::GetTempPath()) 'b5-other')}) $token
    Check ($wrongWorkspace.Status -eq 400) 'a body naming another workspace is refused by the generic session binding'
    $wrongRoute=Invoke-Console $d2Manager POST '/api/operations' (New-ConsoleRequest $session 'SourceCandidateMappingReview' @{CandidateItemId=[string]$imported.ItemId}) $token
    Check ($wrongRoute.Status -eq 400) 'the mapping review cannot be run as a durable operation'
    $sourceActionOnManager=Invoke-Console $d2Manager POST '/api/view' (New-ConsoleRequest $session 'SourceCandidateList' @{ScanId='x'}) $token
    Check ($sourceActionOnManager.Status -eq 400 -and $sourceActionOnManager.Body.code -ceq 'invalid_request') 'a Manager console refuses the Source candidate list'
    $mappingArguments=@{CandidateItemId=[string]$imported.ItemId;ExpectedInventoryHash=[string]$mappingRead.Body.InventoryHash;ExpectedConfirmationHash=[string]$mappingRead.Body.ConfirmationHash;ExpectedRevision=[int]$mappingRead.Body.DecisionRevision;Decisions=@($goodDecisions|ForEach-Object {@{ReferenceId=[string]$_.ReferenceId;Decision=[string]$_.Decision;FileScopeItemId=[string]$_.FileScopeItemId;DependencyType=[string]$_.DependencyType}})}
    $mappingOperation=New-ConsoleRequest $session 'SourceCandidateMappingSubmit' $mappingArguments;$mappingOperation.operationId=[Guid]::NewGuid().ToString('D');$mappingOperation.idempotencyKey=[Guid]::NewGuid().ToString('D')
    $mappingAccepted=Invoke-Console $d2Manager POST '/api/operations' $mappingOperation $token
    $mappingJob=Wait-ConsoleJob $d2Manager $token ([string]$mappingOperation.operationId)
    Check ($mappingAccepted.Status -eq 202 -and $mappingJob.status -ceq 'ReviewRequired' -and @($mappingJob.outputs|Where-Object {$_.Status -ceq 'SubmittedReviewRequired'}).Count -eq 1) 'the mapping review submit runs as a durable console operation; its job is ReviewRequired with output status SubmittedReviewRequired (re-review and re-approval follow)'
    $afterMapping=Get-WsmCatalog $managerWorkspace $pairId
    Check ($afterMapping.DecisionRevision -gt $mappingReview.DecisionRevision -and @($afterMapping.WorkloadDiscovery.FileScopeMappings|Where-Object {$_.Decision -ceq 'Include'}).Count -eq 1) 'the mapping is stored and the revision advanced'
    $staleMapping=New-ConsoleRequest $session 'SourceCandidateMappingSubmit' $mappingArguments;$staleMapping.operationId=[Guid]::NewGuid().ToString('D');$staleMapping.idempotencyKey=[Guid]::NewGuid().ToString('D')
    $staleReply=Invoke-Console $d2Manager POST '/api/operations' $staleMapping $token
    Check ($staleReply.Status -eq 409 -and $staleReply.Body.code -ceq 'stale_revision') 'resubmitting the same mapping against the changed catalog is refused with 409 and no worker'
    $freshSession=Get-ConsoleSession $d2Manager
    $wrongHashOperation=New-ConsoleRequest $freshSession 'SourceCandidateMappingSubmit' @{CandidateItemId=[string]$imported.ItemId;ExpectedInventoryHash=('0'*64);ExpectedConfirmationHash=[string]$mappingRead.Body.ConfirmationHash;ExpectedRevision=[int]$freshSession.decisionRevision;Decisions=$mappingArguments.Decisions};$wrongHashOperation.operationId=[Guid]::NewGuid().ToString('D');$wrongHashOperation.idempotencyKey=[Guid]::NewGuid().ToString('D')
    $null=Invoke-Console $d2Manager POST '/api/operations' $wrongHashOperation $token
    $wrongHashJob=Wait-ConsoleJob $d2Manager $token ([string]$wrongHashOperation.operationId)
    Check ($wrongHashJob.status -ceq 'Failed' -and $wrongHashJob.error.code -ceq 'stale_context') 'a wrong inventory hash fails the durable mapping job with the stale_context code'
    # Source console: the list is served, Manager actions are refused
    $d2Source=Start-ConsoleProcess $sourceWorkspace '' 'Source' $root 'd2-source'
    $sourceSession=Get-ConsoleSession $d2Source;$sourceToken=[string]$sourceSession.token
    $listRead=Invoke-Console $d2Source POST '/api/view' (New-ConsoleRequest $sourceSession 'SourceCandidateList' @{ScanId=[string]$scan.ScanId}) $sourceToken
    Check ($listRead.Status -eq 200 -and $listRead.Body.CandidateHash -ceq $scan.CandidateHash -and @($listRead.Body.Candidates|Where-Object {$_.CandidateId -ceq $candidate.CandidateId}).Count -eq 1) 'the Source console serves the candidate list with the scan artifact hash'
    $managerActionOnSource=Invoke-Console $d2Source POST '/api/view' (New-ConsoleRequest $sourceSession 'SourceCandidateConfirmReview' @{ItemId=[string]$imported.ItemId}) $sourceToken
    Check ($managerActionOnSource.Status -eq 400 -and $managerActionOnSource.Body.code -ceq 'invalid_request') 'a Source console refuses the Manager confirmation review'
    $exportAsView=Invoke-Console $d2Source POST '/api/view' (New-ConsoleRequest $sourceSession 'SourceCandidateConfirmExport' @{ScanId=[string]$scan.ScanId;ExpectedCandidateHash=[string]$scan.CandidateHash;CandidateId=[string]$candidate.CandidateId}) $sourceToken
    Check ($exportAsView.Status -eq 400) 'the export is refused on the read endpoint'
    Write-Output ('PASS Test-C2D2HtmlActions: '+$script:checks+' action map, role/route gate, argument, C2 batch/CAS, D2 flow, closed projection and real console checks.')
}finally{
    Stop-ConsoleProcess $d2Source;Stop-ConsoleProcess $d2Manager
    Remove-TestRoot $root $d2Prefix
}
