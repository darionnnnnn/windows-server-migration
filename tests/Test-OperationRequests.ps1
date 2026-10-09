#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
& $module {foreach($action in (Get-WsmOperationActions).GetEnumerator()){if($action.Value -isnot [string] -or @(Get-Command -Name $action.Value -CommandType Function -ErrorAction Stop).Count -ne 1){throw ('Operation action does not resolve to exactly one local function: '+$action.Key)}}}
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-requests-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root);$path=Join-Path $root 'request.json'
foreach($request in @(
    @{SchemaVersion=1;ToolVersion='0.3.0';Kind='OperationRequest';Action='Invoke-Expression';Arguments=@{Command='bad'}},
    @{SchemaVersion=1;ToolVersion='0.3.0';Kind='OperationRequest';Action='CheckJournal';Arguments=@{Debug=$true}},
    @{SchemaVersion=1;ToolVersion='0.3.0';Kind='OperationRequest';Action='FreezeSource';Arguments=@{}},
    @{SchemaVersion=1;ToolVersion='0.3.0';Kind='OperationRequest';Action='Restore';Arguments=@{Secrets=@{Password='must-not-accept'}}}
)){
    [IO.File]::WriteAllText($path,($request | ConvertTo-Json -Depth 12));$blocked=$false;try{Invoke-WsmOperationRequest $path (Get-FileHash $path).Hash | Out-Null}catch{if($_.Exception -isnot [IO.InvalidDataException]){throw};$blocked=$true};if(-not $blocked){throw 'Untrusted/interactive request accepted'}
}
if((Get-WsmOperationStatusCode ([pscustomobject]@{Stage='RebootRequired'})) -ne 2 -or (Get-WsmOperationStatusCode ([pscustomobject]@{Stage='Failed'})) -ne 1 -or (Get-WsmOperationStatusCode ([pscustomobject]@{Blocked=$true})) -ne 2){throw 'Operation exit classification mismatch'}
foreach($case in @(@{Status='Failed';Code=1},@{Status='Succeeded';Code=0},@{Status='Blocked';Code=2},@{Status='Partial';Code=2},@{Status='RetryPending';Code=2},@{Status='Cancelled';Code=3},@{Status='Running';Code=2},@{Status='ManualEvidenceRequired';Code=2})){
    foreach($stage in @('Export','Restore','Cutover','Retirement')){if((Get-WsmOperationStatusCode ([pscustomobject]@{Kind='StageResult';Stage=$stage;Status=$case.Status})) -ne $case.Code){throw ('StageResult Status exit-code mismatch: '+$stage+'/'+$case.Status)}}
}
if((Get-WsmOperationStatusCode @([pscustomobject]@{Status='Blocked'},[pscustomobject]@{Status='Failed'})) -ne 1){throw 'Earlier blocked result masked a later failure.'}
foreach($statusCode in @{Failed=1;Cancelled=3;Blocked=2;Succeeded=0}.GetEnumerator()) {
    $receipt=[pscustomobject]@{Path='fixture.json';SHA256=('a'*64);Result=[pscustomobject]@{Kind='StageResult';Stage='Restore';Status=$statusCode.Key}}
    if((Get-WsmOperationStatusCode $receipt) -ne $statusCode.Value){throw ('Receipt wrapper hid operation status: '+$statusCode.Key)}
}
Write-Host ('PASS: command/common-parameter/secret injection and missing mandatory noninteractive arguments rejected. Evidence: '+$root)
& $module {
    param($requestRoot)
    $outputRoot=Join-Path $requestRoot 'whatif-output'
    $requestPath=Join-Path $requestRoot 'initialize-request.json'
    Write-WsmJson $requestPath ([pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='OperationRequest';Action='OutputInitialize';Arguments=[pscustomobject]@{WorkRoot=$outputRoot;Role='Manager'}})
    $result=Invoke-WsmOperationRequest $requestPath (Get-FileHash $requestPath).Hash -WhatIf
    if([IO.Directory]::Exists($outputRoot) -or $result.Executed -ne $false -or $result.GatesEvaluated -ne $false){throw 'WhatIf invoked an operation without its own ShouldProcess support.'}
    $script:acceptanceCalls=0
    function Get-WsmAcceptanceGates {param($ManifestPath,$ExpectedHash,$StateDirectory)$script:acceptanceCalls++;[IO.File]::WriteAllText((Join-Path $requestRoot 'unexpected-get-write.txt'),'unexpected')}
    Write-WsmJson $requestPath ([pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='OperationRequest';Action='Acceptance';Arguments=[pscustomobject]@{ManifestPath='fixture.json';ExpectedHash=('a'*64);StateDirectory=$outputRoot}})
    $result=Invoke-WsmOperationRequest $requestPath (Get-FileHash $requestPath).Hash -WhatIf
    if($script:acceptanceCalls -ne 0 -or [IO.File]::Exists((Join-Path $requestRoot 'unexpected-get-write.txt')) -or $result.Executed -ne $false){throw 'WhatIf assumed a Get-named command was free of persistent side effects.'}
    Write-Output 'PASS: operation-request WhatIf creates no output or enrollment for a non-ShouldProcess command.'
} $root
