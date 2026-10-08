#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
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
Write-Host ('PASS: command/common-parameter/secret injection and missing mandatory noninteractive arguments rejected. Evidence: '+$root)
