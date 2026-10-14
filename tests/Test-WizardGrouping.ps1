#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$workspaceRoot=Join-Path ([IO.Path]::GetTempPath()) ('wsm-wizard-grouping-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($workspaceRoot)
try {
    & $module {
        param($Root)
        function Check([bool]$ok,[string]$message){if(-not $ok){throw $message}}
        function Reject([scriptblock]$action,[string]$message){$rejected=$false;try{& $action|Out-Null}catch{$rejected=$true};Check $rejected $message}
        function Item([string]$kind,[string]$name,[string]$key){New-WsmItem $script:groupingHostId Web $kind $name $key @{Name=$name;NaturalKey=$key}}
        function Link($from,$to){$from.Dependencies=@(@($from.Dependencies)+@([pscustomobject]@{ItemId=[string]$to.ItemId;Type='Mandatory'}))}
        $script:groupingHostId=[Guid]::NewGuid().ToString('D')

        # Exercise the actual module grouping consumer: identity, dependency closure,
        # shared-resource impact, cycle and missing-dependency warnings.
        $siteA=Item IISSite 'Same display name' 'site-a';$siteB=Item IISSite 'Same display name' 'site-b'
        $poolA=Item IISPool 'Exclusive pool' 'pool-a';$poolShared=Item IISPool 'Shared pool' 'pool-shared'
        Link $siteA $poolA;Link $siteA $poolShared;Link $siteB $poolShared
        $groups=@(Get-WsmWizardGroups @($siteA,$siteB,$poolA,$poolShared) @{} @{} $null)
        Check ($groups.Count -eq 3) 'Exclusive settings were split from their sole consumer or a shared setting was duplicated.'
        $groupA=@($groups|Where-Object {$_.itemIds -contains $siteA.ItemId})[0];$groupB=@($groups|Where-Object {$_.itemIds -contains $siteB.ItemId})[0]
        Check ($groupA.groupId -cne $groupB.groupId -and $groupA.itemIds -contains $poolA.ItemId) 'Same-name workloads merged or their exclusive dependency was lost.'
        $shared=@($groups|Where-Object {$_.itemIds -contains $poolShared.ItemId})[0]
        Check ($shared.itemIds.Count -eq 1 -and $shared.sharedImpact -and @($shared.affectedItemIds|Where-Object {$_ -in @($siteA.ItemId,$siteB.ItemId)}).Count -eq 2) 'Shared resource was counted more than once or did not expose each consumer.'
        $reordered=@(Get-WsmWizardGroups @($poolShared,$poolA,$siteB,$siteA) @{} @{} $null)
        Check ((@($reordered|Where-Object {$_.itemIds -contains $siteA.ItemId})[0].groupId) -ceq $groupA.groupId) 'Group identity changed with input enumeration order.'
        $cycleA=Item Service 'Cycle A' 'cycle-a';$cycleB=Item Service 'Cycle B' 'cycle-b';Link $cycleA $cycleB;Link $cycleB $cycleA
        $cycleGroups=@(Get-WsmWizardGroups @($cycleA,$cycleB) @{} @{} $null)
        Check ($cycleGroups.Count -eq 2 -and @($cycleGroups|Where-Object {$_.dependencyWarnings.Count -gt 0}).Count -eq 2) 'A dependency cycle was hidden or merged.'
        $missing=Item ScheduledTask 'Missing dependency' 'missing';$missing.Dependencies=@([pscustomobject]@{ItemId=('f'*64);Type='Mandatory'})
        Check (@(Get-WsmWizardGroups @($missing) @{} @{} $null)[0].dependencyWarnings.Count -eq 1) 'An unknown mandatory dependency was hidden.'
        Reject {Get-WsmWizardGroups @($siteA,$siteA) @{} @{} $null} 'Duplicate ItemId was accepted as two group members.'
        Reject {Get-WsmWizardGroups @([pscustomobject]@{Kind='Service'}) @{} @{} $null} 'An inventory item without stable identity was accepted.'

        # Import a genuine 200-item inventory to Manager and exercise the durable
        # wizard/core choice APIs, reopening from disk after every state transition.
        $manager=Join-Path $Root 'manager-200';[void](Initialize-WsmOutputWorkspace -WorkRoot $manager -Role Manager);Initialize-WsmWorkspace $manager|Out-Null
        $facts=[pscustomobject]@{HostId=$script:groupingHostId;Fingerprint=('a'*64);Name='grouping-fixture-source'}
        $many=New-Object 'System.Collections.Generic.List[object]'
        for($i=0;$i -lt 200;$i++){
            switch($i%3){
                0 {$kind='Service';$category='Services';$settings=@{Name=('Service '+$i);PathName=('C:\fixture\svc'+$i+'.exe')}}
                1 {$kind='ScheduledTask';$category='Tasks';$settings=@{Xml=('<Task><Actions><Exec><Command>C:\fixture\task'+$i+'.exe</Command></Exec></Actions></Task>')}}
                2 {$kind='IISSite';$category='Web';$settings=@{Xml=('<site name="site-'+$i+'" />')}}
            }
            $many.Add((New-WsmItem $facts.HostId $category $kind ($kind+' '+$i) ('workload-'+$i) $settings))
        }
        $excludedId=[string]$many[3].ItemId;$dependentId=[string]$many[4].ItemId
        $many[4].Dependencies=@([pscustomobject]@{ItemId=$excludedId;Type='Mandatory'})
        $cycleLeft=[string]$many[5].ItemId;$cycleRight=[string]$many[6].ItemId
        $many[5].Dependencies=@([pscustomobject]@{ItemId=$cycleRight;Type='Mandatory'});$many[6].Dependencies=@([pscustomobject]@{ItemId=$cycleLeft;Type='Mandatory'})
        $missingId=('f'*64);$many[7].Dependencies=@([pscustomobject]@{ItemId=$missingId;Type='Mandatory'})
        $missingDependencyOwnerId=[string]$many[7].ItemId
        $many[8].Dependencies=@([pscustomobject]@{ItemId=[string]$many[9].ItemId;Type='Mandatory'});$many[9].Dependencies=@([pscustomobject]@{ItemId=[string]$many[10].ItemId;Type='Mandatory'})
        $inventory=New-WsmInventory $facts 1 @($many.ToArray());$inventoryPath=Join-Path $Root 'manager-inventory-v1.json';Write-WsmJson $inventoryPath $inventory
        $inventoryHash=(Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $catalog=Import-WsmInventory -Workspace $manager -Path $inventoryPath -ExpectedHash $inventoryHash -TargetName 'Fixture target'
        $catalog=Enable-WsmAssistiveMode $manager $catalog.PairId $catalog.DecisionRevision
        $state=Get-WsmWizardState $manager $catalog.PairId Manager
        $state=Set-WsmWizardState -Workspace $manager -PairId $catalog.PairId -Role Manager -ExpectedWizardRevision $state.Revision -Changes ([pscustomobject]@{CurrentStep='review';Mode='ItemByItem'})
        $projection=Get-WsmWizardProjection $manager $catalog.PairId Manager @()
        Check ($projection.groups.Count -eq 200) 'The real 200-item catalog did not project one stable review group per service.'
        $groupById=@{};foreach($group in $projection.groups){foreach($id in $group.itemIds){$groupById[[string]$id]=$group}}
        Check (@($projection.groups|Where-Object {$_.itemIds -contains $cycleLeft -and $_.dependencyWarnings.Count -gt 0}).Count -eq 1 -and @($projection.groups|Where-Object {$_.itemIds -contains $missingDependencyOwnerId -and $_.dependencyWarnings.Count -gt 0}).Count -eq 1) 'Cycle or missing dependency warning did not remain attached to its real catalog item.'
        $reason='Preserve this service as an explicit Manager exclusion.'
        $excludedChoice=Set-WsmWizardChoice -Workspace $manager -PairId $catalog.PairId -Role Manager -ItemId $excludedId -GroupId $groupById[$excludedId].groupId -Selected $false -Reason $reason -ExpectedDecisionRevision $projection.context.catalogRevision -ExpectedSelectionRevision $projection.context.selectionRevision -ExpectedWizardRevision $projection.revision
        $projection=Get-WsmWizardProjection $manager $catalog.PairId Manager @()
        $includedId=[string]$many[0].ItemId
        $includedChoice=Set-WsmWizardChoice -Workspace $manager -PairId $catalog.PairId -Role Manager -ItemId $includedId -GroupId $groupById[$includedId].groupId -Selected $true -ExpectedDecisionRevision $projection.context.catalogRevision -ExpectedSelectionRevision $projection.context.selectionRevision -ExpectedWizardRevision $projection.revision
        $projection=Get-WsmWizardProjection $manager $catalog.PairId Manager @()
        $beforeAuto=Get-WsmCatalog $manager $catalog.PairId
        $excludedBefore=@($beforeAuto.Items|Where-Object ItemId -CEQ $excludedId)[0]
        Check ($excludedBefore.Decision -ceq 'Exclude' -and $excludedBefore.Reason -ceq $reason -and $excludedChoice.AuthoritativeApproval -eq $false -and $includedChoice.AuthoritativeApproval -eq $false) 'Durable item-by-item choices or their explicit exclusion reason were not stored as non-authoritative intent.'

        $state=Set-WsmWizardState -Workspace $manager -PairId $catalog.PairId -Role Manager -ExpectedWizardRevision $projection.revision -Changes ([pscustomobject]@{Mode='Automatic'})
        $reopened=Get-WsmWizardState $manager $catalog.PairId Manager
        Check ($reopened.Mode -ceq 'Automatic' -and $reopened.Revision -eq $state.Revision) 'Automatic mode did not persist across a fresh state read.'
        $projection=Get-WsmWizardProjection $manager $catalog.PairId Manager @()
        $auto=Invoke-WsmWizardAutomaticChoices -Workspace $manager -PairId $catalog.PairId -Role Manager -ExpectedWizardRevision $projection.revision -ExpectedDecisionRevision $projection.context.catalogRevision -ExpectedSelectionRevision $projection.context.selectionRevision -ExpectedAssistiveRevision $projection.context.assistiveRevision
        $afterAuto=Get-WsmCatalog $manager $catalog.PairId
        $excludedAfter=@($afterAuto.Items|Where-Object ItemId -CEQ $excludedId)[0];$dependentAfter=@($afterAuto.Items|Where-Object ItemId -CEQ $dependentId)[0]
        Check ($excludedAfter.Decision -ceq 'Exclude' -and $excludedAfter.Reason -ceq $reason -and -not (@($auto.AppliedItemIds) -contains $excludedId)) 'Automatic choices overwrote an explicit exclusion or its reason.'
        Check ($dependentAfter.Decision -ceq 'Pending' -and @($auto.SkippedItemIds) -contains $dependentId) 'Automatic choices included an item whose mandatory dependency was explicitly excluded.'
        Check ($auto.AppliedItemIds.Count -eq 194 -and $auto.AuthoritativeApproval -eq $false -and @($many[8].ItemId,$many[9].ItemId,$many[10].ItemId|Where-Object {$auto.AppliedItemIds -contains $_}).Count -eq 3) 'Automatic choices did not apply exactly the eligible pending items or were misrepresented as approval.'
        $autoProjection=Get-WsmWizardProjection $manager $catalog.PairId Manager @()
        Check ($autoProjection.automaticReviewCurrent -and $autoProjection.state.AutomaticReview.Status -ceq 'Completed') 'Automatic review marker was not durable/current after reopening the wizard projection.'

        # A fresh imported item starts pending and unconfirmed even though the
        # prior 200-item set has durable decisions and review markers.
        $many.Add((New-WsmItem $facts.HostId Web Service 'New inventory item' 'service-new' @{Name='New inventory item';PathName='C:\fixture\new.exe'}))
        $newId=[string]$many[$many.Count-1].ItemId
        $inventory2=New-WsmInventory $facts 2 @($many.ToArray());$inventoryPath2=Join-Path $Root 'manager-inventory-v2.json';Write-WsmJson $inventoryPath2 $inventory2
        $inventoryHash2=(Get-FileHash -LiteralPath $inventoryPath2 -Algorithm SHA256).Hash.ToLowerInvariant()
        $catalog2=Import-WsmInventory -Workspace $manager -Path $inventoryPath2 -ExpectedHash $inventoryHash2
        $projection2=Get-WsmWizardProjection $manager $catalog2.PairId Manager @()
        $newChild=@($projection2.groups|ForEach-Object children|Where-Object itemId -CEQ $newId)[0]
        $excludedAfterReopen=@((Get-WsmCatalog $manager $catalog2.PairId).Items|Where-Object ItemId -CEQ $excludedId)[0]
        Check ($newChild -and -not $newChild.confirmed -and $newChild.decision -ceq 'Pending' -and $newChild.selected -eq [bool](@((Get-WsmAssistiveCurrentSelections $catalog2).Items|Where-Object ItemId -CEQ $newId)[0].Selected)) 'A newly inventoried item inherited confirmation/decision state or contradicted current core selection.'
        Check ($excludedAfterReopen.Decision -ceq 'Exclude' -and $excludedAfterReopen.Reason -ceq $reason) 'Explicit exclusion and reason were lost after importing a newer inventory.'
        Check (@($projection2.groups|Where-Object {$_.itemIds -contains $cycleLeft -and $_.dependencyWarnings.Count -gt 0}).Count -eq 1 -and @($projection2.groups|Where-Object {$_.itemIds -contains $missingDependencyOwnerId -and $_.dependencyWarnings.Count -gt 0}).Count -eq 1) 'Cycle or missing dependency warning was lost while importing a new inventory revision.'

        $state=Get-WsmWizardState $manager $catalog2.PairId Manager
        $state=Set-WsmWizardState -Workspace $manager -PairId $catalog2.PairId -Role Manager -ExpectedWizardRevision $state.Revision -Changes ([pscustomobject]@{Mode='ItemByItem'})
        $remainderProjection=Get-WsmWizardProjection $manager $catalog2.PairId Manager @()
        $remainder=Invoke-WsmWizardAutomaticChoices -Workspace $manager -PairId $catalog2.PairId -Role Manager -ExpectedWizardRevision $remainderProjection.revision -ExpectedDecisionRevision $remainderProjection.context.catalogRevision -ExpectedSelectionRevision $remainderProjection.context.selectionRevision -ExpectedAssistiveRevision $remainderProjection.context.assistiveRevision -ConfirmRemainingChoices
        $afterRemainder=Get-WsmCatalog $manager $catalog2.PairId;$excludedRemainder=@($afterRemainder.Items|Where-Object ItemId -CEQ $excludedId)[0];$newRemainder=@($afterRemainder.Items|Where-Object ItemId -CEQ $newId)[0]
        $reopenedProjection=Get-WsmWizardProjection $manager $catalog2.PairId Manager @()
        Check ($remainder.Status -ceq 'SavedRemainder' -and $reopenedProjection.remainderReviewCurrent -and $reopenedProjection.state.Mode -ceq 'ItemByItem') 'Remainder review did not persist as an item-by-item durable review.'
        Check ($excludedRemainder.Decision -ceq 'Exclude' -and $excludedRemainder.Reason -ceq $reason -and -not (@($remainder.AppliedItemIds) -contains $excludedId)) 'Remainder review overwrote the explicit exclusion or its reason.'
        Check ($newRemainder.Decision -ceq 'Include' -and @($remainder.AppliedItemIds) -contains $newId -and $remainder.AuthoritativeApproval -eq $false) 'Remainder review failed to apply the newly inventoried eligible item or implied approval.'
        Check ($reopenedProjection.state.RemainderReview.Status -ceq 'Completed' -and $reopenedProjection.groups.Count -eq 201) 'Reopening after remainder review lost its marker or current 201-item grouping.'
        Write-Output 'PASS: actual module grouping consumer, real durable 200-item Manager choice/mode/reopen flow, dependency gate, and new-item remainder review.'
    } $workspaceRoot
} finally {
    $full=[IO.Path]::GetFullPath($workspaceRoot);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if(-not $full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike 'wsm-wizard-grouping-*'){throw 'Unsafe grouping fixture cleanup path.'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
