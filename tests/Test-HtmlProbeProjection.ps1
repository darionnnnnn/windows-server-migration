# Narrow regression for the native Developer Probe HTTP result projection.
#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function CallModule([scriptblock]$Block,[object[]]$Arguments=@()){& $script:module $Block @Arguments}
try {
    $raw=[pscustomobject][ordered]@{
        Status='Completed'
        SHA256=('a'*64)
        RunId='probe-run-fixture'
        ArchiveBytes=[long]12345
        CollectorCounts=[pscustomobject][ordered]@{Completed=4;Partial=1;PermissionDenied=0;NotApplicable=2;TimedOut=0;Failed=0;Cancelled=0;NotScheduled=0;Path='C:\\private\\nested';Secret='password=nested-secret'}
        ProductionQualified=$false
        BusinessValidated=$false
        Path='C:\private\developer-probes\probe.zip'
        HtmlPath='C:\private\developer-probes\index.html'
        Secret='password=must-not-leak'
    }
    $projected=@(CallModule {param($value) Get-WsmHtmlResultProjection $value} @(@($raw)))[0]
    $record=[pscustomobject]@{action='DeveloperProbe';status='Succeeded';workspace='C:\private';outputs=@($projected);idempotencyKey='private-key';RequestHash=('b'*64)}
    $public=CallModule {param($value) ConvertTo-WsmHtmlPublicJobRecord $value} @($record)
    $json=ConvertTo-Json -InputObject $public -Depth 30 -Compress
    $output=@($public.outputs)[0]
    Check ($output.ProductionQualified -ceq $false -and $output.BusinessValidated -ceq $false) 'Probe qualification flags were dropped or changed by the closed result projection.'
    Check ([long]$output.ArchiveBytes -eq 12345) 'Probe archive byte count was dropped by the closed result projection.'
    Check ($output.CollectorCounts.Completed -eq 4 -and $output.CollectorCounts.Partial -eq 1 -and $output.CollectorCounts.NotScheduled -eq 0) 'Safe collector counts were dropped or changed by the closed result projection.'
    Check (-not $json.Contains('C:\private') -and -not $json.Contains('must-not-leak') -and -not $json.Contains('nested-secret') -and -not $json.Contains('Secret') -and -not $json.Contains('Path')) 'Private paths or secret-bearing fields crossed the public Developer Probe job projection.'
    Check (-not $public.PSObject.Properties['idempotencyKey'] -and -not $public.PSObject.Properties['RequestHash']) 'Private request metadata crossed the public Developer Probe job projection.'
    'Test-HtmlProbeProjection passed.'
}
finally {Remove-Module $module -Force -ErrorAction SilentlyContinue}
