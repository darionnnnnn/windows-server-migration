#requires -Version 5.1
# N9c2 browser fixture: 由真實的投影函式產生，瀏覽器測試只負責顯示。
param([Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking 3>$null
$json=& $module {
    $hostId='11111111-2222-3333-4444-555555555555'
    $context=[pscustomobject]@{Kind='SourceResolutionContext';MachineEnvironment=@();ExcludedEnvironmentNames=@('WSM_SECRET_TOKEN');Accounts=@()}
    function New-Candidate([string]$Original,[string]$Resolved,[string]$Basis,[string[]]$Variables){
        New-WsmItem $hostId Storage PathCandidate $Original ('candidate:'+$Original.ToLowerInvariant()) @{OriginalPath=$Original;ResolvedCandidate=$Resolved;ResolutionBasis=$Basis;ResolutionVariables=@($Variables);RequiresScopeApproval=$true;Reason='Confirm.'} @() Unsupported
    }
    $longTail=('Deep\Folder\'*14)
    $items=@(
        (New-Candidate '%SystemDrive%\Data' 'C:\Data' 'Machine' @('SystemDrive')),
        (New-Candidate '%APPDATA%\Svc' 'C:\Users\svc\AppData\Roaming\Svc' 'ProfileDerived' @('APPDATA')),
        (New-Candidate 'D:\Literal\Path' 'D:\Literal\Path' 'Literal' @()),
        (New-Candidate '%USERPROFILE%\<b>tool</b>\app.exe' '' 'Unresolved' @('USERPROFILE')),
        (New-Candidate ('%APP_HOME%\'+$longTail+'worker.exe') '' 'Unresolved' @('APP_HOME')),
        (New-Candidate '%WSM_SECRET_TOKEN%\vault' '' 'Unresolved' @('WSM_SECRET_TOKEN'))
    )
    $groups=@(Get-WsmWizardGroups $items @{} @{} $null)
    # 每個項目一組，方便瀏覽器逐一切換。
    $xml='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Actions><Exec><Command>%USERPROFILE%\run.exe</Command></Exec></Actions></Task>'
    $consumer=[pscustomobject]@{ItemId=('f'*64);Name='夜間匯出排程';Kind='ScheduledTask';Settings=[pscustomobject]@{Xml=$xml}}
    $probe=[pscustomobject]@{Probe='ConsumerPathResolution';ErrorKind='SourcePathUnresolved';ItemId=('f'*64)}
    $view=Get-WsmCoveragePathResolutionView @($consumer) $probe
    $rows=@([pscustomobject][ordered]@{ItemId=('f'*64);ItemName='夜間匯出排程';ItemKind='ScheduledTask';Resolution=$view;InjectedValue='SECRET-VALUE-MUST-NOT-LEAK-9f3a'})
    $c2=ConvertTo-WsmWizardHtmlValue ([pscustomobject]@{Kind='AssistiveSoftwareDispositionReview';PathResolutions=$rows})
    [pscustomobject]@{groups=$groups;c2PathResolutions=$c2.PathResolutions} | ConvertTo-Json -Depth 20 -Compress
}
[IO.File]::WriteAllText($OutputPath,$json,(New-Object Text.UTF8Encoding($false)))
