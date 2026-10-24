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
    # Q2: UNC 路徑的責任標示。沿用外部共享（無證據）、含標記字元的路徑，以及有通過驗證的 RemoteStorage 契約的另行遷移。
    function New-RemoteEndpoint([string]$Side,[string]$Relative,[string]$RootUnc,[string]$ShareId,[string]$RootId){[pscustomobject]@{Provider=[pscustomobject]@{ProviderKind='SMB fixture provider';ServerIdentity=($Side+'-server-id');ShareIdentity=$ShareId;RootIdentity=$RootId;IdentityEvidence=('evidence://'+$Side+'/provider')};Aliases=@([pscustomobject]@{Kind='Direct';RootUnc=$RootUnc;Evidence=('evidence://'+$Side+'/alias')});RelativePath=$Relative}}
    $remoteSource=New-RemoteEndpoint 'source' 'appA' '\\q2-source\data\root' 'source-share-id' 'source-root-id'
    $remoteTarget=New-RemoteEndpoint 'target' 'appA' '\\q2-target\apps\root' 'target-share-id' 'target-root-id'
    $remote=[pscustomobject]@{Version=1;Source=$remoteSource;Target=$remoteTarget;Ownership=[pscustomobject]@{TokenRef='q2-ownership-ref';Owner='Storage owner';Evidence='evidence://q2/ownership'};Consistency=[pscustomobject]@{PlanId='q2-plan';Revision=3;Method='OwnerFreeze';Writers=@([pscustomobject]@{Identity='q2-writer';Action='Stopped';Evidence='evidence://q2/writer'});FreezeEvidence='evidence://q2/freeze'};Artifact=[pscustomobject]@{ArtifactId='q2-artifact';GenerationId='q2-generation';ManifestHash=('A'*64);ScopeBindingSHA256=(Get-WsmRemoteStorageScopeBindingHash ([pscustomobject]@{Source=$remoteSource;Target=$remoteTarget}));PlanId='q2-plan';PlanRevision=3}}
    $separate=New-WsmItem $hostId Storage DataRoot 'Q2 separate migration' 'q2-separate' ([pscustomobject]@{Path='\\q2-source\data\root\appA\data'}) @() Unsupported
    $separate|Add-Member NoteProperty MigrationSpec ([pscustomobject]@{Adapter='ManualWorkflow';Owner='Storage owner';Evidence='evidence://spec';Product='Remote storage';Procedure='Owner-managed';Artifacts=@();BusinessChecks=@('check');RemoteStorage=$remote})
    $uncItems=@(
        (New-Candidate '\\fs1\data\app' '\\fs1\data\app' 'Literal' @()),
        (New-Candidate '\\fs1\<b>share<b>\<script>alert(1)<x>' '\\fs1\<b>share<b>\<script>alert(1)<x>' 'Literal' @()),
        $separate
    )
    $uncGroups=@(Get-WsmWizardGroups $uncItems @{} @{} $null)
    # 每個項目一組，方便瀏覽器逐一切換。
    $xml='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Actions><Exec><Command>%USERPROFILE%\run.exe</Command></Exec></Actions></Task>'
    $consumer=[pscustomobject]@{ItemId=('f'*64);Name='夜間匯出排程';Kind='ScheduledTask';Settings=[pscustomobject]@{Xml=$xml}}
    $probe=[pscustomobject]@{Probe='ConsumerPathResolution';ErrorKind='SourcePathUnresolved';ItemId=('f'*64)}
    $view=Get-WsmCoveragePathResolutionView @($consumer) $probe
    $rows=@([pscustomobject][ordered]@{ItemId=('f'*64);ItemName='夜間匯出排程';ItemKind='ScheduledTask';Resolution=$view;InjectedValue='SECRET-VALUE-MUST-NOT-LEAK-9f3a'})
    $c2=ConvertTo-WsmWizardHtmlValue ([pscustomobject]@{Kind='AssistiveSoftwareDispositionReview';PathResolutions=$rows})
    [pscustomobject]@{groups=$groups;uncGroups=$uncGroups;c2PathResolutions=$c2.PathResolutions} | ConvertTo-Json -Depth 20 -Compress
}
[IO.File]::WriteAllText($OutputPath,$json,(New-Object Text.UTF8Encoding($false)))
