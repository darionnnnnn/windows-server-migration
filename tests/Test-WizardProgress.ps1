#requires -Version 5.1
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force
$module=Get-Module WindowsServerMigration
if(-not (& $module {Get-Command Get-WsmHtmlProgressProjection -CommandType Function -ErrorAction SilentlyContinue})){
    throw 'Required HtmlConsole progress consumer seam Get-WsmHtmlProgressProjection is not integrated; progress tests must exercise actual worker records.'
}
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
$worker=[Management.Automation.PowerShell]::Create();$handle=$null
try{
    $activity="Backup fixture`r`n"+('a'*300)
    $status='Scanning selected scope; password=fixture-secret'
    $operation="Inspecting files`n"+('b'*300)
    $scriptText=@'
param($activity,$status,$operation)
Write-Progress -Id 96 -Activity $activity -Status $status -CurrentOperation $operation -PercentComplete -1
Start-Sleep -Milliseconds 1500
Write-Progress -Id 96 -Activity 'Backup fixture' -Status 'Copying verified data' -CurrentOperation 'CopyPayloadChunk' -PercentComplete 25
Start-Sleep -Milliseconds 1500
'worker complete'
'@
    $null=$worker.AddScript($scriptText).AddArgument($activity).AddArgument($status).AddArgument($operation)
    $handle=$worker.BeginInvoke()
    # The formal dispatcher stores jobs as hashtables, not PSCustomObjects.
    $job=@{Record=[pscustomobject]@{pairId=[Guid]::NewGuid().ToString();operationId=[Guid]::NewGuid().ToString()};PowerShell=$worker;CancellationToken=$null}
    $deadline=[DateTime]::UtcNow.AddSeconds(8)
    while($worker.Streams.Progress.Count -lt 1 -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
    Check ($worker.Streams.Progress.Count -ge 1) 'Asynchronous worker did not publish its real Write-Progress record.'
    $unknown=& $module {param($value) Get-WsmHtmlProgressProjection $value} $job
    Check ($null -eq $unknown.percent) 'Unknown PowerShell PercentComplete=-1 was projected as a numeric percent.'
    Check ($unknown.activity.Length -le 256 -and $unknown.activity -notmatch '[\r\n]') 'Progress activity was not bounded and control-character sanitized.'
    Check ($unknown.statusDescription -match 'Scanning selected scope' -and $unknown.statusDescription -notmatch 'fixture-secret' -and $unknown.statusDescription -match '\[redacted\]') 'Progress status was lost or exposed a secret-like value.'
    Check ($unknown.currentOperation.Length -le 256 -and $unknown.currentOperation -notmatch '[\r\n]') 'Current operation was not bounded and control-character sanitized.'
    Check ($null -eq $unknown.processedCount) 'Progress projection invented a processed count when the worker supplied none.'
    Check (-not $unknown.PSObject.Properties['eta'] -and -not $unknown.PSObject.Properties['secondsRemaining']) 'Progress projection invented an ETA or remaining-time estimate.'
    $updated=[DateTimeOffset]::MinValue;Check ([DateTimeOffset]::TryParse([string]$unknown.updatedUtc,[ref]$updated)) 'Progress projection omitted its observation timestamp.'
    $deadline=[DateTime]::UtcNow.AddSeconds(8)
    while(([int]$worker.Streams.Progress[$worker.Streams.Progress.Count-1].PercentComplete -ne 25) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
    $known=& $module {param($value) Get-WsmHtmlProgressProjection $value} $job
    Check ($known.percent -eq 25 -and $known.currentOperation -ceq 'CopyPayloadChunk' -and $known.statusDescription -ceq 'Copying verified data') 'A real numeric worker progress record did not retain its safe operation/status values.'
    $job.processedCount=7
    $counted=& $module {param($value) Get-WsmHtmlProgressProjection $value} $job
    Check ($counted.processedCount -eq 7) 'Progress projection did not preserve an explicitly supplied processed count.'
    [void]$worker.EndInvoke($handle);$handle=$null
    Write-Host 'PASS: async HTML progress preserves truthful unknown/numeric percent, bounded safe text and timestamp.'
}finally{
    if($handle -and $worker.InvocationStateInfo.State -notin @('Completed','Failed','Stopped')){try{$worker.Stop()}catch{}}
    if($handle){try{[void]$worker.EndInvoke($handle)}catch{}}
    $worker.Dispose()
}
