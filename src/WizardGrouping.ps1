function Get-WsmWizardGroupId([string]$Family,[string[]]$ItemIds) {
    $ids=@($ItemIds | ForEach-Object {[string]$_} | Sort-Object -Unique)
    'wg-'+(Get-WsmHashText ($Family.ToLowerInvariant()+'|'+($ids -join '|'))).Substring(0,24)
}

function Get-WsmWizardGroups($Items,$SelectionIndex,$ResultIndex,$WorkloadDiscovery,$ConfirmedIndex=@{},$FileDetailIndex=@{}) {
    if($null -eq $SelectionIndex){$SelectionIndex=@{}};if($null -eq $ResultIndex){$ResultIndex=@{}};if($null -eq $ConfirmedIndex){$ConfirmedIndex=@{}};if($null -eq $FileDetailIndex){$FileDetailIndex=@{}}
    $rows=@($Items);$index=@{};$edges=@{};$consumers=@{};$warnings=@{};$owner=@{};$buckets=@{}
    foreach($item in $rows){
        $id=[string]$item.ItemId
        if(-not $id){throw 'Inventory item without a stable ItemId cannot be grouped.'}
        if($index.ContainsKey($id)){throw 'Duplicate inventory item identity blocks workload grouping.'}
        $index[$id]=$item;$edges[$id]=New-Object 'System.Collections.Generic.List[string]';$consumers[$id]=New-Object 'System.Collections.Generic.List[string]';$warnings[$id]=New-Object 'System.Collections.Generic.List[string]'
    }
    foreach($item in $rows){
        $id=[string]$item.ItemId
        if($item.PSObject.Properties['Dependencies']){foreach($dep in @($item.Dependencies)){
            $target=[string]$dep.ItemId
            if(-not $target -or -not $index.ContainsKey($target)){$warnings[$id].Add('必要相依項目未出現在目前盤點中，必須先確認完整資料。');continue}
            if(-not $edges[$id].Contains($target)){$edges[$id].Add($target);if(-not $consumers[$target].Contains($id)){$consumers[$target].Add($id)}}
        }}
    }
    if($WorkloadDiscovery -and $WorkloadDiscovery.PSObject.Properties['References']){foreach($ref in @($WorkloadDiscovery.References)){
        $id=[string]$ref.ConsumerItemId;$target=[string]$ref.ResourceItemId
        if(-not $index.ContainsKey($id)){continue}
        if(-not $target -or -not $index.ContainsKey($target)){
            if($ref.Required -or $ref.ReviewRequired){$warnings[$id].Add('必要的相關路徑或設定無法辨識，必須由負責人確認。')};continue
        }
        if(-not $edges[$id].Contains($target)){$edges[$id].Add($target);if(-not $consumers[$target].Contains($id)){$consumers[$target].Add($id)}}
    }}
    # Iterative reachability marks each member of a dependency cycle without recursion.
    foreach($id in @($index.Keys | Sort-Object)){
        $pending=New-Object 'System.Collections.Generic.Stack[string]';foreach($next in $edges[$id]){$pending.Push($next)};$seen=@{}
        while($pending.Count){$next=$pending.Pop();if($next -ceq $id){$warnings[$id].Add('相依項目形成循環，必須先確認處理順序。');break};if($seen.ContainsKey($next)){continue};$seen[$next]=$true;foreach($child in $edges[$next]){$pending.Push($child)}}
    }
    foreach($id in @($index.Keys | Sort-Object)){
        $item=$index[$id];$kind=[string]$item.Kind;$family='configuration';$label='設定與其他項目';$key='configuration|'+$id
        if($kind -ceq 'IISSite'){$family='website';$label='網站';$key=$family+'|'+$id}
        elseif($kind -ceq 'ScheduledTask'){$family='task';$label='排程工作';$key=$family+'|'+$id}
        elseif($kind -ceq 'Service'){$family='service';$label='服務';$key=$family+'|'+$id}
        elseif($kind -in @('PathCandidate','FileScope','TaskFolder')){$family='folder';$label='資料夾與檔案';$path=[string]$item.NaturalKey;$key=$family+'|'+$path.TrimEnd('\').ToLowerInvariant()}
        elseif($kind -in @('IISPool','IISGlobalConfig','IISSectionConfig','IISLocationConfig','IISWebConfig','IISWebConfigObservation')){$family='configuration';$label='服務設定與資料夾'}
        elseif($item.Category -ceq 'Runtime'){$family='software';$label='軟體設定'}
        $owner[$id]=$key
        if(-not $buckets.ContainsKey($key)){$buckets[$key]=[ordered]@{Family=$family;Label=$label;NaturalKey=[string]$item.NaturalKey;Items=(New-Object 'System.Collections.Generic.List[object]');DependencyWarnings=(New-Object 'System.Collections.Generic.List[string]')}}
        $buckets[$key].Items.Add($item)
    }
    # A dependency with one business consumer is one workload question. Shared resources stay single and expose every impact.
    $businessKinds=@('IISSite','ScheduledTask','Service');$changed=$true
    while($changed){$changed=$false;foreach($id in @($index.Keys | Sort-Object)){
        $item=$index[$id];if($item.Kind -in $businessKinds -or $warnings[$id].Count -or $consumers[$id].Count -ne 1){continue}
        $parent=$consumers[$id][0];if(-not $owner.ContainsKey($parent)){continue};$parentKey=$owner[$parent];$oldKey=$owner[$id]
        if($buckets[$parentKey].Family -notin @('website','task','service') -or $oldKey -ceq $parentKey){continue}
        [void]$buckets[$oldKey].Items.Remove($item);$buckets[$parentKey].Items.Add($item);$owner[$id]=$parentKey;$changed=$true
    }}
    foreach($id in @($index.Keys | Sort-Object)){foreach($warning in $warnings[$id]){$key=$owner[$id];if(-not $buckets[$key].DependencyWarnings.Contains($warning)){$buckets[$key].DependencyWarnings.Add($warning)}}}
    foreach($key in @($buckets.Keys)){if(-not $buckets[$key].Items.Count){$buckets.Remove($key)}}
    $groups=New-Object 'System.Collections.Generic.List[object]'
    foreach($key in @($buckets.Keys | Sort-Object)){
        $b=$buckets[$key];$memberIds=@($b.Items | ForEach-Object {[string]$_.ItemId} | Sort-Object -Unique);$first=@($b.Items | Sort-Object ItemId)[0]
        $selectedCount=@($memberIds | Where-Object {$SelectionIndex.ContainsKey([string]$_) -and [bool]$SelectionIndex[[string]$_]}).Count
        $affected=New-Object 'System.Collections.Generic.List[string]';foreach($memberId in $memberIds){if(-not $affected.Contains($memberId)){$affected.Add($memberId)}}
        if($WorkloadDiscovery -and $WorkloadDiscovery.PSObject.Properties['SharedResources']){foreach($resource in @($WorkloadDiscovery.SharedResources)){if($resource.PSObject.Properties['ConsumerItemIds'] -and @($resource.ConsumerItemIds | Where-Object {$memberIds -contains [string]$_}).Count){foreach($consumer in @($resource.ConsumerItemIds)){if(-not $affected.Contains([string]$consumer)){$affected.Add([string]$consumer)}}}}}
        foreach($memberId in $memberIds){foreach($consumer in $consumers[$memberId]){if(-not $affected.Contains([string]$consumer)){$affected.Add([string]$consumer)}}}
        $children=@(foreach($member in $b.Items){
            $id=[string]$member.ItemId;$decision='Pending';if($member.PSObject.Properties['Decision']){$decision=[string]$member.Decision};$status=[string]$member.Status;$reason='';if($member.PSObject.Properties['Reason']){$reason=[string]$member.Reason}
            $deps=@();if($member.PSObject.Properties['Dependencies']){$deps=@($member.Dependencies | ForEach-Object {[string]$_.ItemId})}
            $supported=($status -notin @('Unsupported','Failed','PermissionDenied') -and $member.Kind -notin @('DiscoveryGap','CollectorFailure','UnsupportedCollector'));$unsupportedReason=''
            if(-not $supported){$unsupportedReason='核心目前標記此項目不支援或盤點失敗。'}
            if($member.PSObject.Properties['Classification']){$class=[string]$member.Classification.Disposition;if($class -ceq 'SpecialProduct'){$supported=$false;$unsupportedReason='特殊伺服器產品必須由負責人採人工安裝或外部處理。'}elseif($class -ceq 'Preparation'){$supported=$false;$unsupportedReason='執行環境、用戶端、驅動程式與伺服器角色需要在目標端人工準備。'}elseif($class -ceq 'Unknown' -and (-not $member.PSObject.Properties['GeneralHostOverride'] -or $member.GeneralHostOverride.Disposition -cne 'Migrate')){$supported=$false;$unsupportedReason='未知項目須先由負責人確認搬移處置。'}}
            $details=@(Get-WsmWizardFileDetails $member);$detailStatus='NotCaptured'
            if($FileDetailIndex.ContainsKey($id)){$capture=$FileDetailIndex[$id];$detailStatus=[string]$capture.Status;$details=@(foreach($entry in @($capture.Entries)){[pscustomobject][ordered]@{path=[string]$entry.path;status=[string]$entry.status;directory=[bool]$entry.directory;bytes=$entry.bytes;lastWriteUtc=[string]$entry.lastWriteUtc;contentRead=$false}})}
            [pscustomobject][ordered]@{itemId=$id;name=[string]$member.Name;kind=[string]$member.Kind;category=[string]$member.Category;source=[string]$member.NaturalKey;decision=$decision;selected=$(if($SelectionIndex.ContainsKey($id)){[bool]$SelectionIndex[$id]}else{$decision -ceq 'Include'});confirmed=($ConfirmedIndex.ContainsKey($id) -and [bool]$ConfirmedIndex[$id]);dependencies=$deps;reason=$reason;status=$status;executionStatus=$(if($ResultIndex.ContainsKey($id)){$ResultIndex[$id].Status}else{'NotObserved'});supported=$supported;unsupportedReason=$unsupportedReason;fileDetails=$details;fileDetailsStatus=$detailStatus}
        })
        $unsupportedChildren=@($children | Where-Object {-not $_.supported});$groupId=Get-WsmWizardGroupId $b.Family $memberIds
        $groups.Add([pscustomobject][ordered]@{groupId=$groupId;kind=$b.Family;label=$b.Label;name=[string]$first.Name;itemIds=$memberIds;supportedItemIds=@($children | Where-Object supported | ForEach-Object {[string]$_.itemId});affectedItemIds=@($affected.ToArray() | Sort-Object -Unique);selected=($selectedCount -eq $memberIds.Count);confirmed=(@($memberIds | Where-Object {$ConfirmedIndex.ContainsKey([string]$_) -and [bool]$ConfirmedIndex[[string]$_]}).Count -eq $memberIds.Count);selectionState=$(if($selectedCount -eq 0){'Excluded'}elseif($selectedCount -eq $memberIds.Count){'Included'}else{'Partial'});children=$children;sharedImpact=($affected.Count -gt $memberIds.Count);sharedImpactReason=$(if($affected.Count -gt $memberIds.Count){'此共用資源也影響其他搬移項目。'}else{''});dependencies=@($children | ForEach-Object {$_.dependencies} | Select-Object -Unique);dependencyWarnings=@($b.DependencyWarnings.ToArray());supported=($unsupportedChildren.Count -eq 0);unsupportedReason=$(if($unsupportedChildren.Count){'此分組含有不支援或需人工處置的項目，不能整組自動加入。'}else{''})})
    }
    @($groups.ToArray())
}


function Get-WsmWizardAutomaticEligibility($Items,$Candidates,$AlreadyIncluded=@{}) {
    # Resolve the complete eligible dependency closure before making any choices.
    # Missing/excluded dependencies and unresolved cycles stay pending.
    $index=@{};foreach($item in @($Items)){$index[[string]$item.ItemId]=$item}
    $resolved=@{};$changed=$true
    while($changed){$changed=$false;foreach($id in @($Candidates.Keys|Sort-Object)){
        if($resolved.ContainsKey([string]$id) -or -not $index.ContainsKey([string]$id)){continue}
        $valid=$true
        foreach($dependency in @($index[[string]$id].Dependencies|Where-Object Type -CEQ 'Mandatory')){
            $dependencyId=[string]$dependency.ItemId
            if(-not $index.ContainsKey($dependencyId) -or (-not $resolved.ContainsKey($dependencyId) -and -not $AlreadyIncluded.ContainsKey($dependencyId))){$valid=$false;break}
        }
        if($valid){$resolved[[string]$id]=$true;$changed=$true}
    }}
    $resolved
}