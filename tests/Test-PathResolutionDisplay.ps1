#requires -Version 5.1
# N9c2 / R7-07: path resolution basis display (projection layer). Original string, resolved result, basis and
# reason are shown per path; unresolved paths are manual-disposition rows with a reason-specific next step;
# the projection never carries environment variable values.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking 3>$null
$checks=& $module {
    $state=@{n=0}
    function Check($Condition,[string]$Message){if(-not $Condition){throw ('FAIL: '+$Message)};$state.n++}
    $secretValue='SECRET-VALUE-MUST-NOT-LEAK-9f3a'
    $context=[pscustomobject]@{Kind='SourceResolutionContext';MachineEnvironment=@([pscustomobject]@{Name='SystemDrive';Value='C:'},[pscustomobject]@{Name='WSM_SECRET_TOKEN';Value=$secretValue},[pscustomobject]@{Name='APP_HOME';Value='D:\Apps'});ExcludedEnvironmentNames=@('LEGACY_CONN','WSM_SECRET_TOKEN');Accounts=@()}
    function New-Candidate([string]$Original,[string]$Resolved,[string]$Basis,[string[]]$Variables=@(),[string]$Kind='PathCandidate') {
        [pscustomobject]@{ItemId=('c'*64);Kind=$Kind;Settings=[pscustomobject]@{OriginalPath=$Original;ResolvedCandidate=$Resolved;ResolutionBasis=$Basis;ResolutionVariables=@($Variables)}}
    }
    # 1) Four bases, one example each, through the real file-detail projection used by the review screen.
    $cases=@(
        @{Item=(New-Candidate '%SystemDrive%\Data' 'C:\Data' 'Machine' @('SystemDrive'));Basis='Machine';Label='機器層';Unresolved=$false}
        @{Item=(New-Candidate '%APPDATA%\Svc' 'C:\Users\svc\AppData\Roaming\Svc' 'ProfileDerived' @('APPDATA'));Basis='ProfileDerived';Label='帳號設定檔推導';Unresolved=$false}
        @{Item=(New-Candidate 'D:\Literal\Path' 'D:\Literal\Path' 'Literal' @());Basis='Literal';Label='字面路徑';Unresolved=$false}
        @{Item=(New-Candidate '%APP_HOME%\bin' '' 'Unresolved' @('APP_HOME'));Basis='Unresolved';Label='未解析';Unresolved=$true}
    )
    foreach($case in $cases){
        $rows=@(Get-WsmWizardFileDetails $case.Item)
        Check ($rows.Count -eq 1 -and $rows[0].PSObject.Properties['resolution']) ('Missing resolution row for '+$case.Basis)
        $view=$rows[0].resolution
        Check ($view.basis -ceq $case.Basis -and $view.basisLabel -ceq $case.Label) ('Basis/label wrong for '+$case.Basis)
        Check ($view.original -ceq [string]$case.Item.Settings.OriginalPath) ('Original string not shown for '+$case.Basis)
        Check ($view.unresolved -eq $case.Unresolved -and $view.manual -eq $case.Unresolved) ('Unresolved/manual flag wrong for '+$case.Basis)
        if($case.Unresolved){
            Check ($null -eq $view.resolved -and $view.resolvedText -ceq '未解析') 'Unresolved result must be null and shown as 未解析.'
            Check ($rows[0].status -ceq 'ManualDisposition' -and $rows[0].path -ceq $case.Item.Settings.OriginalPath) 'Unresolved row is not a manual-disposition row on the original string.'
            Check ($view.reasonCode -and $view.reasonLabel -and $view.nextStep) 'Unresolved row lacks reason or next step.'
        } else {
            Check ($view.resolved -ceq [string]$case.Item.Settings.ResolvedCandidate -and $view.resolvedText -ceq $view.resolved) ('Resolved path missing for '+$case.Basis)
            Check ($view.reasonCode -ceq '' -and $view.nextStep -ceq '' -and $rows[0].status -ceq 'ScopeNotEnumerated') ('Resolved row carries manual markers for '+$case.Basis)
        }
    }
    # In-memory items (just inventoried) keep Settings as a hashtable; the projection must read both shapes.
    $memoryItem=New-WsmItem '11111111-2222-3333-4444-555555555555' Storage PathCandidate '%APP_HOME%\x' 'candidate:%app_home%\x' @{OriginalPath='%APP_HOME%\x';ResolvedCandidate='';ResolutionBasis='Unresolved';ResolutionVariables=@('APP_HOME')} @() Unsupported
    $memoryRows=@(Get-WsmWizardFileDetails $memoryItem)
    Check ($memoryRows.Count -eq 1 -and $memoryRows[0].resolution.unresolved -and $memoryRows[0].resolution.nextStep -ceq '確認變數在新機的值') 'Hashtable Settings were not projected.'
    # A stale Machine basis with an empty result must not read as resolved.
    $stale=(@(Get-WsmWizardFileDetails (New-Candidate '%X%\a' '' 'Machine' @('X'))))[0].resolution
    Check ($stale.unresolved -and $stale.basis -ceq 'Unresolved' -and $null -eq $stale.resolved) 'Empty result with a resolved basis was shown as resolved.'
    # Items without a recorded basis (older inventories) get no invented basis.
    $legacy=[pscustomobject]@{ItemId=('d'*64);Settings=[pscustomobject]@{OriginalPath='C:\Old';ResolvedCandidate='C:\Old'}}
    $legacyRows=@(Get-WsmWizardFileDetails $legacy)
    Check ($legacyRows.Count -eq 1 -and -not $legacyRows[0].PSObject.Properties['resolution']) 'Legacy item without ResolutionBasis got an invented resolution.'

    # 2) Next step depends on the reason.
    $profile=(New-WsmPathResolutionView -Original '%USERPROFILE%\x' -Resolved '' -Basis 'Unresolved' -Reason 'AccountHasNoProfile')
    Check ($profile.nextStep -ceq '在新機確認該帳號的設定檔路徑') 'Missing-profile next step wrong.'
    $custom=(New-WsmPathResolutionView -Original '%APP_HOME%\x' -Resolved '' -Basis 'Unresolved' -Reason 'VariableNotInSourceContext')
    Check ($custom.nextStep -ceq '確認變數在新機的值') 'Custom-variable next step wrong.'
    Check ($profile.nextStep -cne $custom.nextStep) 'Next steps are not reason specific.'
    $derivedProfile=(New-WsmPathResolutionView -Original '%LOCALAPPDATA%\x' -Resolved '' -Basis 'Unresolved')
    Check ($derivedProfile.reasonCode -ceq 'ProfileVariableUnresolved' -and $derivedProfile.nextStep -ceq $profile.nextStep) 'Derived profile reason wrong.'
    $relative=(New-WsmPathResolutionView -Original '..\up\x' -Resolved '' -Basis 'Unresolved')
    Check ($relative.reasonCode -ceq 'ParentOrCurrentSegment') 'Parent segment reason wrong.'
    # web.config root observation carries the recorded reason.
    $webRoot=[pscustomobject]@{ItemId=('e'*64);Kind='IISWebConfigObservation';Settings=[pscustomobject]@{Status='UnresolvedPhysicalRoot';PhysicalRoot='%USERPROFILE%\site';ResolutionBasis='Unresolved';ResolutionReason='AccountHasNoProfile'}}
    $webRows=@(Get-WsmWizardFileDetails $webRoot)
    Check ($webRows.Count -eq 1 -and $webRows[0].resolution.reasonCode -ceq 'AccountHasNoProfile' -and $webRows[0].resolution.nextStep -ceq '在新機確認該帳號的設定檔路徑') 'web.config root observation lacks recorded reason / next step.'

    # 3) Original string and result are escaped (control / bidi / inline secret assignment / bounded).
    $hostile="C:\a`r`n<script>alert(1)</script>"+[char]0x1B+"[31m"+[char]0x202E+"\password=hunter2\"+('x'*5000)
    $escaped=New-WsmPathResolutionView -Original $hostile -Resolved $hostile -Basis 'Literal'
    foreach($field in @($escaped.original,$escaped.resolved)){
        Check ($field -notmatch '[\x00-\x1F\x7F]' -and $field -notmatch [string][char]0x202E) 'Control or bidi characters survived escaping.'
        Check ($field -match '\\u000D' -and $field -match '\\u001B' -and $field -match '\\u202E') 'Escapes are not visible.'
        Check ($field -notmatch 'hunter2' -and $field -match 'password=\[redacted\]') 'Inline secret assignment was not redacted.'
        Check ($field.Length -le 2048) 'Display text is unbounded.'
    }

    # 4) Excluded secret variables: name only, never a value; no context environment value reaches the projection.
    $secretView=New-WsmPathResolutionView -Original '%WSM_SECRET_TOKEN%\a;%LEGACY_CONN%\b;%APP_HOME%\c' -Resolved '' -Basis 'Unresolved' -Reason '' -Variables @('WSM_SECRET_TOKEN','LEGACY_CONN','APP_HOME') -Context $context
    $byName=@{};foreach($v in @($secretView.variables)){$byName[[string]$v.name]=$v}
    Check ($byName['WSM_SECRET_TOKEN'].excluded -and $byName['LEGACY_CONN'].excluded -and -not $byName['APP_HOME'].excluded) 'Excluded flags wrong.'
    Check ($secretView.reasonCode -ceq 'ExcludedSecretVariable') 'Excluded secret variable reason wrong.'
    foreach($v in @($secretView.variables)){Check (@($v.PSObject.Properties.Name) -join ',' -ceq 'name,excluded') 'Variable rows carry more than name/excluded.'}
    $itemWithContext=New-Candidate '%WSM_SECRET_TOKEN%\a' '' 'Unresolved' @('WSM_SECRET_TOKEN')
    $itemView=Get-WsmItemPathResolutionView $itemWithContext $context
    $everything=($secretView,$itemView,@(Get-WsmWizardFileDetails $itemWithContext)) | ConvertTo-Json -Depth 12
    Check ($everything -notmatch [regex]::Escape($secretValue)) 'Secret variable value leaked into the projection.'
    Check ($everything -notmatch 'D:\\\\Apps') 'Context environment value leaked into the projection.'

    # 5) Software coverage consumer: task command resolved by the single resolver with the Source context.
    $xml='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal id="A"><UserId>S-1-5-21-1-2-3-1001</UserId></Principal></Principals><Actions><Exec><Command>%USERPROFILE%\tool.exe</Command></Exec></Actions></Task>'
    $task=[pscustomobject]@{ItemId=('f'*64);Name='Task';Kind='ScheduledTask';Settings=[pscustomobject]@{Xml=$xml}}
    $ctx2=[pscustomobject]@{Kind='SourceResolutionContext';MachineEnvironment=@([pscustomobject]@{Name='SystemDrive';Value='C:'});ExcludedEnvironmentNames=@();Accounts=@([pscustomobject]@{Account='S-1-5-21-1-2-3-1001';Sid='S-1-5-21-1-2-3-1001';ProfileImagePath=$null})}
    $consumer=Get-WsmConsumerPathResolutionView $task $ctx2
    Check ($consumer.original -ceq '%USERPROFILE%\tool.exe' -and $consumer.unresolved -and $consumer.reasonCode -ceq 'AccountHasNoProfile' -and $consumer.nextStep -ceq '在新機確認該帳號的設定檔路徑') 'Consumer task path resolution view wrong.'
    $consumerNoContext=Get-WsmConsumerPathResolutionView $task $null
    Check ($consumerNoContext.unresolved -and $consumerNoContext.reasonCode -ceq 'ProfileVariableUnresolved') 'Consumer view without context must classify from the string only.'
    $iis=[pscustomobject]@{ItemId=('9'*64);Name='Site';Kind='IISSite';Settings=[pscustomobject]@{Xml='<site><application path="/"><virtualDirectory path="/" physicalPath="%APP_HOME%\www" /></application></site>'}}
    Check ((Get-WsmConsumerPathResolutionView $iis $null).original -ceq '%APP_HOME%\www') 'IIS physicalPath original not shown.'
    # 6) HTML projection (C2 view): closed shape, secret value / unexpected fields dropped, empty list stays an empty list.
    function Get-WsmCatalog($Workspace,$PairId) { [pscustomobject]@{Items=@($task,$iis)} }
    function Get-WsmGeneralHostContract($Catalog) { [pscustomobject]@{SoftwareCatalog=[pscustomobject]@{Coverage=@([pscustomobject]@{Probe='ConsumerPathResolution';ErrorKind='SourcePathUnresolved';ItemId=('f'*64)},[pscustomobject]@{Probe='Uninstall';ErrorKind='';ItemId=''})}} }
    $resolutions=@(Get-WsmHtmlConsumerPathResolutions 'W' 'P')
    Check ($resolutions.Count -eq 1 -and $resolutions[0].Resolution.original -ceq '%USERPROFILE%\tool.exe' -and $resolutions[0].ItemKind -ceq 'ScheduledTask') 'Consumer path resolutions were not collected from coverage rows.'
    $withExtras=@([pscustomobject]@{ItemId=('f'*64);ItemName='Task';ItemKind='ScheduledTask';Resolution=$resolutions[0].Resolution;Leak=$secretValue})
    $withExtras[0].Resolution|Add-Member NoteProperty Value $secretValue -Force
    $view=ConvertTo-WsmHtmlC2D2View ([pscustomobject]@{Kind='AssistiveSoftwareDispositionReview';Rows=@();Coverage=@()}) 'SoftwareDispositionReview' 3 'W' 'P'
    Check (@($view.PathResolutions).Count -eq 1 -and $view.PathResolutions[0].Resolution.basisLabel -ceq '未解析' -and $view.PathResolutions[0].Resolution.unresolved -and $view.viewRevision -eq 3) 'C2 view lacks the path resolution rows.'
    $closed=ConvertTo-WsmWizardHtmlValue ([pscustomobject]@{PathResolutions=$withExtras})
    $closedJson=$closed|ConvertTo-Json -Depth 10
    Check ($closedJson -notmatch [regex]::Escape($secretValue) -and @($closed.PathResolutions[0].PSObject.Properties.Name) -join ',' -ceq 'ItemId,ItemName,ItemKind,Resolution') 'Closed projection let an unexpected field through.'
    Check (@($closed.PathResolutions[0].Resolution.PSObject.Properties.Name) -notcontains 'Value') 'Closed projection let an unexpected resolution field through.'
    function Get-WsmGeneralHostContract($Catalog) { [pscustomobject]@{SoftwareCatalog=[pscustomobject]@{Coverage=@()}} }
    $emptyView=ConvertTo-WsmHtmlC2D2View ([pscustomobject]@{Kind='AssistiveSoftwareDispositionReview'}) 'SoftwareDispositionReview' 3 'W' 'P'
    Check ($emptyView.PSObject.Properties['PathResolutions'] -and @($emptyView.PathResolutions).Count -eq 0) 'Empty path resolution list is not an empty list.'
    $state.n
}
Write-Output ('Path resolution display projection checks passed: '+$checks)
