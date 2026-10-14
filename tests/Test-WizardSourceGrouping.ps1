#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
& $module {param($path) . $path} (Join-Path $PSScriptRoot '..\src\WizardFlow.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-source-grouping-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$passed=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:passed++}
function Private([scriptblock]$Action){
    $wizardPath=Join-Path $PSScriptRoot '..\src\WizardFlow.ps1';$bound=@($args);$code=$Action.ToString()
    & $script:module {param($path,$code,$boundArguments) . $path; $wizardBoundArguments=$boundArguments; Invoke-Expression ('& { '+$code+' } @wizardBoundArguments')} $wizardPath $code $bound
}
function SaveJson($Data,[string]$Path){[IO.File]::WriteAllText($Path,($Data|ConvertTo-Json -Depth 60 -Compress),(New-Object Text.UTF8Encoding($false)));$Path}
function NewSourceFixture([string]$Name){
    $workspace=Join-Path $script:root $Name
    $profile=Initialize-WsmOutputWorkspace -WorkRoot $workspace -Role Source
    $hostId=[string]$profile.Profile.HostId
    $global=New-WsmItem $hostId Web IISGlobalConfig 'Global IIS configuration' 'global-config' @{Name='global-config'}
    $pool=New-WsmItem $hostId Web IISPool 'Fixture pool' 'fixture-pool' @{Name='FixturePool'} @([pscustomobject]@{ItemId=$global.ItemId;Type='Mandatory';Evidence='fixture dependency'})
    $site=New-WsmItem $hostId Web IISSite 'Fixture site' 'fixture-site' @{Name='Fixture site'} @([pscustomobject]@{ItemId=$pool.ItemId;Type='Mandatory';Evidence='fixture dependency'})
    $missing=New-WsmItem $hostId Services Service 'Missing dependency consumer' 'missing-consumer' @{Name='MissingConsumer'} @([pscustomobject]@{ItemId=('f'*64);Type='Mandatory';Evidence='fixture missing dependency'})
    $cycleA=New-WsmItem $hostId Services Service 'Cycle A' 'cycle-a' @{Name='CycleA'}
    $cycleB=New-WsmItem $hostId Services Service 'Cycle B' 'cycle-b' @{Name='CycleB'} @([pscustomobject]@{ItemId=$cycleA.ItemId;Type='Mandatory';Evidence='fixture cycle'})
    $cycleA.Dependencies=@([pscustomobject]@{ItemId=$cycleB.ItemId;Type='Mandatory';Evidence='fixture cycle'})
    $inventory=New-WsmInventory ([pscustomobject]@{HostId=$hostId;Fingerprint=[string]$profile.Profile.Fingerprint;Name=$Name}) 1 @($site,$pool,$global,$missing,$cycleA,$cycleB)
    $path=Join-Path $profile.InventoryDirectory 'inventory-1.json'
    SaveJson $inventory $path|Out-Null
    $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $job=[pscustomobject]@{jobId=[Guid]::NewGuid().ToString('D');action='Inventory';status='Succeeded';role='Source';workspace=$workspace;CompletedUtc=[DateTime]::UtcNow.ToString('o');outputs=@([pscustomobject]@{Path=$path;SHA256=$hash})}
    [pscustomobject]@{Workspace=$workspace;Profile=$profile.Profile;Inventory=$inventory;Hash=$hash;Job=$job;Items=@{Site=$site;Pool=$pool;Global=$global;Missing=$missing;CycleA=$cycleA;CycleB=$cycleB}}
}
try {
    # The job is the same durable, enrolled-profile binding consumed by the actual Source projection.
    $auto=NewSourceFixture 'automatic'
    $binding=Private {param($workspace,$role,$jobId,$revision,$jobs) Set-WsmWizardInventoryBinding -Workspace $workspace -Role $role -JobId $jobId -ExpectedWizardRevision $revision -Jobs $jobs} $auto.Workspace 'Source' $auto.Job.jobId 0 @($auto.Job)
    $projection=Private {param($workspace,$jobs) Get-WsmWizardProjection $workspace '' Source $jobs} $auto.Workspace @($auto.Job)
    Check ($binding.Status -ceq 'InventoryBound' -and $projection.sourceInventory.sha256 -ceq $auto.Hash -and $projection.sourceInventory.jobId -ceq $auto.Job.jobId -and $projection.scan.itemCount -eq 6) 'Source grouping test did not use the currently enrolled profile and verified durable inventory job.'
    Check (@($projection.groups|ForEach-Object {$_.children}|Where-Object { -not $_.confirmed -and $_.selected }).Count -eq 6) 'Freshly bound source inventory did not remain preselected but unconfirmed.'

    # Simulate a pre-Confirmed persisted row from an older SourceIntent schema.
    # The real automatic path must remain safe under the module StrictMode settings.
    $legacyState=Private {param($workspace) Get-WsmWizardState $workspace '' Source} $auto.Workspace
    $legacyItem=$auto.Items.Site
    $legacyState.SourceIntent=@([pscustomobject]@{ItemId=$legacyItem.ItemId;Selected=$true;Reason='';InventoryHash=$auto.Hash;InventoryRevision=1;UpdatedUtc=[DateTime]::UtcNow.ToString('o')})
    $statePath=Join-Path (Join-Path (Join-Path (Join-Path $auto.Workspace 'workspace-control') 'wizard') 'Source') 'unbound.json'
    SaveJson $legacyState $statePath|Out-Null
    $legacyRoundTrip=Private {param($workspace) Get-WsmWizardState $workspace '' Source} $auto.Workspace
    Check (-not $legacyRoundTrip.SourceIntent[0].PSObject.Properties['Confirmed']) 'Legacy fixture accidentally included the optional Confirmed property.'
    $autoResult=Private {param($workspace,$wizard,$jobs) Invoke-WsmWizardAutomaticChoices -Workspace $workspace -Role Source -ExpectedWizardRevision $wizard -ExpectedDecisionRevision 1 -ExpectedSelectionRevision $wizard -Jobs $jobs} $auto.Workspace $legacyRoundTrip.Revision @($auto.Job)
    $autoSaved=Private {param($workspace,$jobs) Get-WsmWizardProjection $workspace '' Source $jobs} $auto.Workspace @($auto.Job)
    $chainIds=@($auto.Items.Site.ItemId,$auto.Items.Pool.ItemId,$auto.Items.Global.ItemId)
    $chainRows=@($autoSaved.groups|ForEach-Object {$_.children}|Where-Object {$chainIds -contains [string]$_.itemId})
    Check ($autoResult.Status -ceq 'SavedIntent' -and @($autoResult.AppliedItemIds|Where-Object {$chainIds -contains [string]$_}).Count -eq 3 -and $chainRows.Count -eq 3 -and @($chainRows|Where-Object {$_.confirmed -and $_.selected}).Count -eq 3) 'Automatic Source review did not confirm the full eligible mandatory dependency chain.'
    Check (@($autoSaved.groups|ForEach-Object {$_.children}|Where-Object {$_.itemId -ceq $auto.Items.Missing.ItemId -or $_.itemId -in @($auto.Items.CycleA.ItemId,$auto.Items.CycleB.ItemId)}|Where-Object {$_.confirmed -or $_.decision -ceq 'Include'}).Count -eq 0) 'Missing or cyclic dependency items were falsely presented as confirmed Include decisions.'
    Check (@($autoSaved.groups|Where-Object {$_.dependencyWarnings.Count -gt 0}).Count -ge 2) 'The Source projection did not expose dependency warnings for missing and cyclic dependency groups.'
    Check ($autoSaved.automaticReviewCurrent -and $autoSaved.state.AutomaticReview.Status -ceq 'Completed' -and $autoSaved.state.Mode -ceq 'Automatic') 'Source Automatic review completion was not durably reopened against the same inventory and intent.'

    # A separate Source workspace explicitly excludes the chain's middle item.
    # The selected site consumer must remain pending, while its exclusion reason survives Automatic.
    $excluded=NewSourceFixture 'explicit-exclusion'
    [void](Private {param($workspace,$role,$jobId,$revision,$jobs) Set-WsmWizardInventoryBinding -Workspace $workspace -Role $role -JobId $jobId -ExpectedWizardRevision $revision -Jobs $jobs} $excluded.Workspace 'Source' $excluded.Job.jobId 0 @($excluded.Job))
    $beforeExclude=Private {param($workspace,$jobs) Get-WsmWizardProjection $workspace '' Source $jobs} $excluded.Workspace @($excluded.Job)
    $excludeChoice=Private {param($workspace,$id,$revision,$jobs) Set-WsmWizardChoice -Workspace $workspace -Role Source -ItemId $id -Selected $false -Reason 'Owner chose to omit this shared prerequisite.' -ExpectedDecisionRevision $revision -ExpectedSelectionRevision 1 -ExpectedWizardRevision 1 -Jobs $jobs} $excluded.Workspace $excluded.Items.Pool.ItemId 1 @($excluded.Job)
    $beforeAuto=Private {param($workspace,$jobs) Get-WsmWizardProjection $workspace '' Source $jobs} $excluded.Workspace @($excluded.Job)
    $excludedResult=Private {param($workspace,$wizard,$jobs) Invoke-WsmWizardAutomaticChoices -Workspace $workspace -Role Source -ExpectedWizardRevision $wizard -ExpectedDecisionRevision 1 -ExpectedSelectionRevision $wizard -Jobs $jobs} $excluded.Workspace $beforeAuto.revision @($excluded.Job)
    $excludedAfter=Private {param($workspace,$jobs) Get-WsmWizardProjection $workspace '' Source $jobs} $excluded.Workspace @($excluded.Job)
    $siteAfter=@($excludedAfter.groups|ForEach-Object {$_.children}|Where-Object itemId -CEQ $excluded.Items.Site.ItemId)[0]
    $poolAfter=@($excludedAfter.groups|ForEach-Object {$_.children}|Where-Object itemId -CEQ $excluded.Items.Pool.ItemId)[0]
    $poolIntent=@($excludedAfter.state.SourceIntent|Where-Object ItemId -CEQ $excluded.Items.Pool.ItemId)[0]
    Check ($beforeExclude.revision -eq 1 -and $excludeChoice.Revision -eq 2) 'Explicit prerequisite exclusion did not use the current Source wizard revision.'
    Check (-not $siteAfter.confirmed -and $siteAfter.selected -and $siteAfter.decision -ceq 'Pending' -and $excluded.Items.Site.ItemId -notin @($excludedResult.AppliedItemIds)) 'A selected consumer whose mandatory prerequisite was explicitly excluded became confirmed Include.'
    Check (-not $poolAfter.selected -and $poolAfter.confirmed -and $poolIntent.Reason -ceq 'Owner chose to omit this shared prerequisite.' -and $excluded.Items.Pool.ItemId -notin @($excludedResult.AppliedItemIds)) 'Automatic Source selection lost the explicit exclusion or its reason.'
    Check ($excludedAfter.automaticReviewCurrent -and $excludedAfter.state.SourceIntent.Count -ge 1) 'The exclusion and its automatic review result were not durably reopened.'
    Write-Host ('PASS: '+$passed+' real Source projection, verified job binding, dependency closure, pending warnings, legacy intent and exclusion persistence checks.')
} finally {Remove-Item -LiteralPath $root -Recurse -Force}
