#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
foreach($case in @(@{Exception=(New-Object TimeoutException('fixture'));Category='Timeout'},@{Exception=(New-Object UnauthorizedAccessException('fixture'));Category='Permission'},@{Exception=(New-Object IO.InvalidDataException('fixture'));Category='InputValidation'})){$details=Get-WsmFailureDetails $case.Exception;if($details.Category -cne $case.Category -or $details.AutomaticRetrySafe -or $details.RawOutputIncluded -or -not $details.Hint){throw 'Failure category/hint contract incorrect'}}
& $module {
    foreach($case in @(@{Code=5;Category='Permission'},@{Code=112;Category='Capacity'},@{Code=1053;Category='Timeout'},@{Code=1060;Category='ObjectMissing'},@{Code=1072;Category='PendingDeletion'})){$error=New-WsmNativeFailure sc.exe $case.Code 'fixture';$wrapped=New-Object InvalidOperationException('wrapper',$error);$details=Get-WsmFailureDetails $wrapped;if($details.NativeCode -ne $case.Code -or $details.NativeTool -cne 'sc.exe' -or $details.Category -cne $case.Category){throw 'Wrapped native code or classified advice lost'}}
    function script:Invoke-WsmNativeTool {param($Tool,$Arguments)[pscustomobject]@{Succeeded=$false;NativeCode=5}}
    $blocked=$false;try{Get-WsmServiceSecurity Fixture}catch{$details=Get-WsmFailureDetails $_;$blocked=$true;if($details.NativeCode -ne 5 -or $details.Category -ne 'Permission'){throw 'Service security query lost native code'}};if(-not $blocked){throw 'Failed service security query accepted'}
}
Write-Host 'PASS: typed failures, nested native exit codes and actionable hints without raw output or automatic retry.'
