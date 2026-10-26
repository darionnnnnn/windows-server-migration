function Assert-WsmRemoteText([string]$Value,[string]$Name,[int]$Maximum=512) {
    if([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt $Maximum -or $Value -ne $Value.Trim() -or $Value -match '[\x00-\x1f\x7f]'){
        throw (New-WsmContractError ('Remote storage '+$Name+' must be a bounded, nonempty reviewed value.'))
    }
}

function ConvertTo-WsmRemoteIdentity([string]$Value) {
    return $Value.Trim().ToUpperInvariant()
}

function ConvertTo-WsmRemoteRelativePath([string]$Path,[switch]$AllowRoot) {
    if($AllowRoot -and $Path -ceq ''){return ''}
    if([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains('/') -or $Path.StartsWith('\') -or $Path.EndsWith('\') -or $Path.Contains(':') -or $Path -match '[\x00-\x1f\x7f<>"|?*]' -or $Path -match '\\{2,}'){
        throw (New-WsmContractError 'Remote storage relative path is not canonical.')
    }
    $segments=@($Path.Split('\'))
    foreach($segment in $segments){
        if($segment -in @('.','..') -or $segment -match '[. ]$' -or $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){
            throw (New-WsmContractError 'Remote storage relative path contains an unsafe segment.')
        }
    }
    return ($segments -join '\')
}

function ConvertTo-WsmRemoteUncRoot([string]$Path) {
    if([string]::IsNullOrWhiteSpace($Path) -or $Path -ne $Path.Trim() -or $Path -notmatch '^\\\\[^\\]+\\[^\\]+(?:\\.*)?$' -or $Path -match '^\\\\[?.]\\' -or $Path.Contains('/') -or $Path -match '[\x00-\x1f\x7f<>"|?*:]' -or $Path.EndsWith('\')){
        throw (New-WsmContractError 'Remote storage alias must be a canonical UNC root.')
    }
    $segments=@($Path.Substring(2).Split('\'))
    foreach($segment in $segments){
        if([string]::IsNullOrWhiteSpace($segment) -or $segment -in @('.','..') -or $segment -match '[. ]$' -or $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){
            throw (New-WsmContractError 'Remote storage alias contains an unsafe UNC segment.')
        }
    }
    return $Path
}

function Get-WsmRemotePathComparison([string]$Path) {
    return $Path.TrimEnd('\').ToUpperInvariant()
}

function Get-WsmRemoteStorageEndpointScopeHash($Endpoint) {
    $provider=$Endpoint.Provider
    $providerKey=ConvertTo-Json -InputObject @((ConvertTo-WsmRemoteIdentity ([string]$provider.ServerIdentity)),(ConvertTo-WsmRemoteIdentity ([string]$provider.ShareIdentity)),(ConvertTo-WsmRemoteIdentity ([string]$provider.RootIdentity))) -Compress
    $relative=(ConvertTo-WsmRemoteRelativePath ([string]$Endpoint.RelativePath) -AllowRoot).ToUpperInvariant()
    return (Get-WsmHashText (ConvertTo-Json -InputObject @($providerKey,$relative) -Compress))
}

function Get-WsmRemoteStorageScopeBindingHash($RemoteStorage) {
    $source=Get-WsmRemoteStorageEndpointScopeHash $RemoteStorage.Source
    $target=Get-WsmRemoteStorageEndpointScopeHash $RemoteStorage.Target
    return (Get-WsmHashText (ConvertTo-Json -InputObject @('RemoteStorageScopeV1',$source,$target) -Compress))
}

function Test-WsmRemotePathOverlap([string]$Left,[string]$Right) {
    $a=Get-WsmRemotePathComparison $Left; $b=Get-WsmRemotePathComparison $Right
    if(-not $a -or -not $b){return $true}
    return (Test-WsmPathOverlap $a $b)
}

function Assert-WsmRemoteEndpoint($Endpoint,[string]$Side) {
    Assert-WsmFields $Endpoint @('Provider','Aliases','RelativePath') @('Provider','Aliases','RelativePath')
    $provider=$Endpoint.Provider
    Assert-WsmFields $provider @('ProviderKind','ServerIdentity','ShareIdentity','RootIdentity','IdentityEvidence') @('ProviderKind','ServerIdentity','ShareIdentity','RootIdentity','IdentityEvidence')
    foreach($field in @('ProviderKind','ServerIdentity','ShareIdentity','RootIdentity','IdentityEvidence')){Assert-WsmRemoteText ([string]$provider.$field) ($Side+'.Provider.'+$field)}
    if(@($Endpoint.Aliases).Count -eq 0){throw (New-WsmContractError ('Remote storage '+$Side+' requires at least one declared alias.'))}
    [void](ConvertTo-WsmRemoteRelativePath ([string]$Endpoint.RelativePath) -AllowRoot)
    $seen=@{}; $roots=@()
    foreach($alias in $Endpoint.Aliases){
        Assert-WsmFields $alias @('Kind','RootUnc','Evidence','ReferralEvidence') @('Kind','RootUnc','Evidence')
        if($alias.Kind -cnotin @('Direct','DFS')){throw (New-WsmContractError 'Remote storage alias kind must be Direct or DFS.')}
        $root=ConvertTo-WsmRemoteUncRoot ([string]$alias.RootUnc)
        Assert-WsmRemoteText ([string]$alias.Evidence) ($Side+'.Alias.Evidence')
        if($alias.Kind -ceq 'DFS'){Assert-WsmRemoteText ([string]$alias.ReferralEvidence) ($Side+'.Alias.ReferralEvidence')}
        elseif($alias.PSObject.Properties['ReferralEvidence'] -and -not [string]::IsNullOrWhiteSpace([string]$alias.ReferralEvidence)){Assert-WsmRemoteText ([string]$alias.ReferralEvidence) ($Side+'.Alias.ReferralEvidence')}
        $key=Get-WsmRemotePathComparison $root
        if($seen.ContainsKey($key)){throw (New-WsmContractError ('Duplicate '+$Side+' UNC alias root.'))}
        foreach($priorRoot in $roots){if(Test-WsmRemotePathOverlap $root $priorRoot){throw (New-WsmContractError ('Overlapping '+$Side+' UNC alias roots do not identify one exact provider root.'))}}
        $seen[$key]=$true
        $roots+=@($root)
    }
}

function Assert-WsmRemoteStorageContract($RemoteStorage,[string]$Owner) {
    Assert-WsmFields $RemoteStorage @('Version','Source','Target','Ownership','Consistency','Artifact') @('Version','Source','Target','Ownership','Consistency','Artifact')
    if([int]$RemoteStorage.Version -ne 1){throw (New-WsmContractError 'Unsupported remote storage contract version.')}
    Assert-WsmRemoteEndpoint $RemoteStorage.Source 'Source'
    Assert-WsmRemoteEndpoint $RemoteStorage.Target 'Target'

    Assert-WsmFields $RemoteStorage.Ownership @('TokenRef','Owner','Evidence') @('TokenRef','Owner','Evidence')
    Assert-WsmRemoteText ([string]$RemoteStorage.Ownership.TokenRef) 'Ownership.TokenRef'
    Assert-WsmRemoteText ([string]$RemoteStorage.Ownership.Owner) 'Ownership.Owner'
    Assert-WsmRemoteText ([string]$RemoteStorage.Ownership.Evidence) 'Ownership.Evidence'
    if($Owner -and $RemoteStorage.Ownership.Owner -ine $Owner){throw (New-WsmContractError 'Remote storage ownership owner differs from the migration spec owner.')}

    $consistency=$RemoteStorage.Consistency
    Assert-WsmFields $consistency @('PlanId','Revision','Method','Writers','FreezeEvidence') @('PlanId','Revision','Method','Writers','FreezeEvidence')
    Assert-WsmRemoteText ([string]$consistency.PlanId) 'Consistency.PlanId'
    if(($consistency.Revision -isnot [int] -and $consistency.Revision -isnot [long]) -or [long]$consistency.Revision -lt 1){throw (New-WsmContractError 'Remote storage consistency revision must be a positive integer.')}
    if($consistency.Method -cnotin @('OwnerFreeze','ProductBackup','ImmutableSnapshot')){throw (New-WsmContractError 'Remote storage consistency method is unsupported.')}
    Assert-WsmRemoteText ([string]$consistency.FreezeEvidence) 'Consistency.FreezeEvidence'
    if(@($consistency.Writers).Count -eq 0){throw (New-WsmContractError 'Remote storage consistency plan must declare every writer.')}
    $writers=@{}
    foreach($writer in $consistency.Writers){
        Assert-WsmFields $writer @('Identity','Action','Evidence') @('Identity','Action','Evidence')
        Assert-WsmRemoteText ([string]$writer.Identity) 'Consistency.Writer.Identity'
        Assert-WsmRemoteText ([string]$writer.Evidence) 'Consistency.Writer.Evidence'
        if($writer.Action -cnotin @('Stopped','Quiesced','ProductSnapshot')){throw (New-WsmContractError 'Remote storage writer action must be explicitly reviewed.')}
        if($consistency.Method -ceq 'OwnerFreeze' -and $writer.Action -notin @('Stopped','Quiesced')){throw (New-WsmContractError 'OwnerFreeze requires each writer to be stopped or quiesced.')}
        if($consistency.Method -in @('ProductBackup','ImmutableSnapshot') -and $writer.Action -cne 'ProductSnapshot'){throw (New-WsmContractError 'ProductBackup and ImmutableSnapshot require each writer to be covered by the product snapshot.')}
        $writerKey=ConvertTo-WsmRemoteIdentity ([string]$writer.Identity)
        if($writers.ContainsKey($writerKey)){throw (New-WsmContractError 'Remote storage consistency writer is duplicated.')}
        $writers[$writerKey]=$true
    }

    $artifact=$RemoteStorage.Artifact
    Assert-WsmFields $artifact @('ArtifactId','GenerationId','ManifestHash','ScopeBindingSHA256','PlanId','PlanRevision') @('ArtifactId','GenerationId','ManifestHash','ScopeBindingSHA256','PlanId','PlanRevision')
    foreach($field in @('ArtifactId','GenerationId','PlanId')){Assert-WsmRemoteText ([string]$artifact.$field) ('Artifact.'+$field)}
    if([string]$artifact.ManifestHash -notmatch '^[A-Fa-f0-9]{64}$'){throw (New-WsmContractError 'Remote storage artifact manifest hash must be SHA-256.')}
    if([string]$artifact.ScopeBindingSHA256 -notmatch '^[A-Fa-f0-9]{64}$' -or $artifact.ScopeBindingSHA256 -ine (Get-WsmRemoteStorageScopeBindingHash $RemoteStorage)){throw (New-WsmContractError 'Remote storage artifact is not bound to the reviewed source and target scopes.')}
    if(($artifact.PlanRevision -isnot [int] -and $artifact.PlanRevision -isnot [long]) -or $artifact.PlanId -cne $consistency.PlanId -or [long]$artifact.PlanRevision -ne [long]$consistency.Revision){throw (New-WsmContractError 'Remote storage artifact is not bound to the reviewed consistency plan revision.')}

    return [pscustomobject]@{Valid=$true;SourceScopeRelativePath=(ConvertTo-WsmRemoteRelativePath ([string]$RemoteStorage.Source.RelativePath) -AllowRoot);TargetScopeRelativePath=(ConvertTo-WsmRemoteRelativePath ([string]$RemoteStorage.Target.RelativePath) -AllowRoot);ConsistencyMethod=$consistency.Method;ArtifactId=$artifact.ArtifactId;GenerationId=$artifact.GenerationId}
}

function Get-WsmRemoteStorageClaims($Items) {
    foreach($item in $Items){
        if($item.Decision -cne 'Include' -or -not $item.MigrationSpec -or $item.MigrationSpec.Adapter -cne 'ManualWorkflow' -or -not $item.MigrationSpec.PSObject.Properties['RemoteStorage'] -or -not $item.MigrationSpec.RemoteStorage){continue}
        $spec=$item.MigrationSpec; $remote=$spec.RemoteStorage
        [void](Assert-WsmRemoteStorageContract $remote ([string]$spec.Owner))
        foreach($side in @('Source','Target')){
            $endpoint=$remote.$side; $provider=$endpoint.Provider; $relative=ConvertTo-WsmRemoteRelativePath ([string]$endpoint.RelativePath) -AllowRoot
            $server=ConvertTo-WsmRemoteIdentity ([string]$provider.ServerIdentity); $share=ConvertTo-WsmRemoteIdentity ([string]$provider.ShareIdentity); $root=ConvertTo-WsmRemoteIdentity ([string]$provider.RootIdentity)
            $paths=New-Object 'System.Collections.Generic.List[string]'
            foreach($alias in $endpoint.Aliases){
                $aliasRoot=ConvertTo-WsmRemoteUncRoot ([string]$alias.RootUnc); $path=$aliasRoot
                if($relative){$path=$aliasRoot.TrimEnd('\')+'\'+$relative}
                [void]$paths.Add((Get-WsmRemotePathComparison $path))
            }
            [pscustomobject]@{ItemId=[string]$item.ItemId;Side=$side;Server=$server;Share=$share;Root=$root;Relative=$relative;Paths=@($paths.ToArray())}
        }
    }
}

function Get-WsmRemotePathSortKey([string]$Path) {
    # Segment delimiters sort before every legal path character. This keeps a
    # path's descendants adjacent to the path itself for the ancestor sweep.
    $builder=New-Object System.Text.StringBuilder
    if([string]::IsNullOrEmpty($Path)){[void]$builder.Append('0001');return $builder.ToString()}
    foreach($segment in $Path.Split('\')){
        foreach($character in $segment.ToCharArray()){
            [void]$builder.Append(([int][char]$character).ToString('X4',[Globalization.CultureInfo]::InvariantCulture))
        }
        [void]$builder.Append('0001')
    }
    return $builder.ToString()
}

function Get-WsmRemoteGroupSortKey([string]$Group) {
    $bytes=[Text.Encoding]::UTF8.GetBytes($Group)
    return [Convert]::ToBase64String($bytes)
}

function Assert-WsmRemotePathIntervals($Rows,[string]$GroupProperty,[string]$PathProperty) {
    $sortable=New-Object 'System.Collections.Generic.List[object]'
    foreach($row in $Rows){
        [void]$sortable.Add([pscustomobject]@{Group=(Get-WsmRemoteGroupSortKey ([string]$row.$GroupProperty));Path=(Get-WsmRemotePathSortKey ([string]$row.$PathProperty));Row=$row})
    }
    $ordered=@($sortable.ToArray() | Sort-Object -Property Group,Path -CaseSensitive)
    $stack=New-Object 'System.Collections.Generic.List[object]'
    $activeGroup=$null
    foreach($entry in $ordered){
        if($null -eq $activeGroup -or $entry.Group -cne $activeGroup){$stack.Clear();$activeGroup=$entry.Group}
        while($stack.Count -gt 0 -and -not $entry.Path.StartsWith([string]$stack[$stack.Count-1].Path,[StringComparison]::Ordinal)){$stack.RemoveAt($stack.Count-1)}
        if($stack.Count -gt 0){
            $left=$stack[$stack.Count-1].Row; $right=$entry.Row
            if($left.ItemId -cne $right.ItemId -or $left.Side -cne $right.Side){
                throw (New-WsmContractError ('Overlapping approved remote storage scopes: '+$left.ItemId+' and '+$right.ItemId+'.'))
            }
        }
        [void]$stack.Add($entry)
    }
}

function Assert-WsmRemoteStorageScopes($Items) {
    $claims=@(Get-WsmRemoteStorageClaims $Items)
    $canonicalRows=@($claims | ForEach-Object {
        $group=ConvertTo-Json -InputObject @($_.Server,$_.Root) -Compress
        [pscustomobject]@{ItemId=$_.ItemId;Side=$_.Side;Group=$group;Path=$_.Relative.ToUpperInvariant()}
    })
    Assert-WsmRemotePathIntervals $canonicalRows 'Group' 'Path'

    # A share identity alone does not prove how distinct roots within that
    # share map to relative paths. Reject conflicting root claims until the
    # provider contract can supply an independently reviewed share-relative map.
    $shareRows=@($claims | ForEach-Object {
        $group=ConvertTo-Json -InputObject @($_.Server,$_.Share) -Compress
        [pscustomobject]@{ItemId=$_.ItemId;Side=$_.Side;Group=$group;Root=$_.Root}
    } | Sort-Object -Property Group,Root -CaseSensitive)
    $lastGroup=$null; $lastRoot=$null; $lastClaim=$null
    foreach($row in $shareRows){
        if($null -ne $lastGroup -and $row.Group -ceq $lastGroup -and $row.Root -cne $lastRoot){
            throw (New-WsmContractError ('Conflicting canonical root identities for one remote share: '+$lastClaim.ItemId+' and '+$row.ItemId+'.'))
        }
        if($null -eq $lastGroup -or $row.Group -cne $lastGroup){$lastGroup=$row.Group;$lastRoot=$row.Root;$lastClaim=$row}
    }

    $aliasRows=New-Object 'System.Collections.Generic.List[object]'
    foreach($claim in $claims){foreach($path in $claim.Paths){[void]$aliasRows.Add([pscustomobject]@{ItemId=$claim.ItemId;Side=$claim.Side;Group='all-unc-paths';Path=$path})}}
    Assert-WsmRemotePathIntervals $aliasRows.ToArray() 'Group' 'Path'
    $scopeKeys=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($claim in $claims){[void]$scopeKeys.Add(([string]$claim.ItemId+'|'+[string]$claim.Side))}
    return [pscustomobject]@{Valid=$true;ScopeCount=$scopeKeys.Count}
}

function Get-WsmRemoteStorageSummary($Items) {
    $rows=@()
    foreach($item in $Items){
        if($item.Decision -cne 'Include' -or -not $item.MigrationSpec -or $item.MigrationSpec.Adapter -cne 'ManualWorkflow' -or -not $item.MigrationSpec.PSObject.Properties['RemoteStorage'] -or -not $item.MigrationSpec.RemoteStorage){continue}
        $remote=$item.MigrationSpec.RemoteStorage
        [void](Assert-WsmRemoteStorageContract $remote ([string]$item.MigrationSpec.Owner))
        $sourceKey=ConvertTo-Json -InputObject @((ConvertTo-WsmRemoteIdentity ([string]$remote.Source.Provider.ServerIdentity)),(ConvertTo-WsmRemoteIdentity ([string]$remote.Source.Provider.ShareIdentity)),(ConvertTo-WsmRemoteIdentity ([string]$remote.Source.Provider.RootIdentity))) -Compress
        $targetKey=ConvertTo-Json -InputObject @((ConvertTo-WsmRemoteIdentity ([string]$remote.Target.Provider.ServerIdentity)),(ConvertTo-WsmRemoteIdentity ([string]$remote.Target.Provider.ShareIdentity)),(ConvertTo-WsmRemoteIdentity ([string]$remote.Target.Provider.RootIdentity))) -Compress
        $artifactKey=ConvertTo-Json -InputObject @($remote.Artifact.ArtifactId,$remote.Artifact.GenerationId,$remote.Artifact.ManifestHash,$remote.Artifact.PlanId,[string]$remote.Artifact.PlanRevision) -Compress
        $rows+=@([pscustomobject]@{ItemId=$item.ItemId;Reviewed=$true;SourceProviderSHA256=(Get-WsmHashText $sourceKey);TargetProviderSHA256=(Get-WsmHashText $targetKey);SourceAliasCount=@($remote.Source.Aliases).Count;TargetAliasCount=@($remote.Target.Aliases).Count;SourceScopeSHA256=(Get-WsmRemoteStorageEndpointScopeHash $remote.Source);TargetScopeSHA256=(Get-WsmRemoteStorageEndpointScopeHash $remote.Target);ConsistencyMethod=$remote.Consistency.Method;ConsistencyRevision=$remote.Consistency.Revision;GenerationBound=$true;ArtifactBindingSHA256=(Get-WsmHashText $artifactKey)})
    }
    return $rows
}

# Q2: UNC 路徑的責任分類（唯讀、純函式）。
# 只有「通過 Assert-WsmRemoteStorageContract 的 RemoteStorage 契約，且契約的來源／目的範圍涵蓋該路徑」才是 SeparateMigration（另行遷移、需另行核准）；
# 其餘一律 ExternalShareReuse（沿用既有外部共享，由外部協調，不自動複製）。分類不會產生任何本機路徑，也不授權任何搬運。
function Test-WsmUncPath([string]$Path) {
    if([string]::IsNullOrWhiteSpace($Path)){return $false}
    return [bool]($Path -match '^\\\\(?![?.]\\)[^\\/]+\\[^\\/]+(?:\\|$)')
}

function Test-WsmRemoteStorageCoversPath($RemoteStorage,[string]$Path) {
    $target=Get-WsmRemotePathComparison $Path
    foreach($side in @('Source','Target')){
        $endpoint=$RemoteStorage.$side
        $relative=ConvertTo-WsmRemoteRelativePath ([string]$endpoint.RelativePath) -AllowRoot
        foreach($alias in @($endpoint.Aliases)){
            $scope=([string]$alias.RootUnc).TrimEnd('\')
            if($relative){$scope=$scope+'\'+$relative}
            $scope=Get-WsmRemotePathComparison $scope
            if(Test-WsmPathWithinRoot $target $scope -Native){return $true}
        }
    }
    return $false
}

function Get-WsmUncResponsibility([string]$Path,$MigrationSpec=$null) {
    # 非 UNC 路徑回傳 $null（沒有責任分類的問題）。
    if(-not (Test-WsmUncPath $Path)){return $null}
    $responsibility='ExternalShareReuse'
    $reason='沒有通過驗證的另行遷移證據（RemoteStorage 契約），視為沿用既有外部共享。'
    $nextStep='由共享的擁有者協調保留共享名稱、DNS 與主機切換；工具不會複製此位置，也不會把它改成本機路徑。'
    $evidence=$false
    $remote=$null
    if($null -ne $MigrationSpec -and $MigrationSpec.PSObject.Properties['RemoteStorage'] -and $MigrationSpec.RemoteStorage){$remote=$MigrationSpec.RemoteStorage}
    if($null -ne $remote){
        $failure=''
        try{
            if([string]$MigrationSpec.Adapter -cne 'ManualWorkflow'){throw 'RemoteStorage requires a dedicated ManualWorkflow.'}
            $owner='';if($MigrationSpec.PSObject.Properties['Owner']){$owner=[string]$MigrationSpec.Owner}
            [void](Assert-WsmRemoteStorageContract $remote $owner)
            if(-not (Test-WsmRemoteStorageCoversPath $remote $Path)){$failure='NotCovered'}
        }catch{
            $failure='Invalid:'+[string]$_.Exception.Message
        }
        if(-not $failure){
            $responsibility='SeparateMigration';$evidence=$true
            $reason='已有通過驗證的 RemoteStorage 契約，來源與目的範圍涵蓋此路徑。'
            $nextStep='依該項目的人工搬移流程另行遷移；需另行核准，工具不自動複製。'
        }elseif($failure -ceq 'NotCovered'){
            $reason='RemoteStorage 契約通過驗證，但其來源與目的範圍都不涵蓋此路徑，退回沿用既有外部共享。'
            $nextStep='確認此路徑是否屬於該契約的範圍；在補上涵蓋此路徑的契約前，工具不會複製。'
        }else{
            $detail=ConvertTo-WsmPathDisplayText ($failure.Substring(8)) 200
            $reason='RemoteStorage 契約未通過驗證（'+$detail+'），退回沿用既有外部共享。'
            $nextStep='補齊並通過 RemoteStorage 契約後才能另行遷移；在此之前工具不會複製。'
        }
    }
    $isSeparate=($responsibility -ceq 'SeparateMigration')
    [pscustomobject][ordered]@{
        Kind='UncResponsibility'
        Path=(ConvertTo-WsmPathDisplayText $Path 1024)
        Responsibility=$responsibility
        Evidence=$evidence
        EvidenceText=$(if($evidence){'有'}else{'無'})
        Label=$(if($isSeparate){'另行遷移'}else{'沿用外部共享'})
        Summary=$(if($isSeparate){'另行遷移，需另行核准'}else{'沿用外部共享，不自動複製'})
        BackupText=$(if($isSeparate){'另行遷移，見核准'}else{'沿用外部共享，未備份'})
        Reason=$reason
        NextStep=$nextStep
        AutomaticCopy=$false
        RewrittenToLocal=$false
    }
}

function Get-WsmItemUncResponsibility($Item,[string[]]$ExtraPath=@()) {
    # 取該項目第一個 UNC 路徑（呼叫端給的顯示位置優先，其次核准規格、盤點設定、RemoteStorage 來源別名），回傳其責任分類；沒有 UNC 則 $null。
    if($null -eq $Item){return $null}
    $spec=$null;if($Item.PSObject.Properties['MigrationSpec'] -and $Item.MigrationSpec){$spec=$Item.MigrationSpec}
    $candidates=New-Object 'System.Collections.Generic.List[string]'
    foreach($path in @($ExtraPath)){if($path){$candidates.Add([string]$path)}}
    if($spec){foreach($name in @('SourcePath','TargetPath')){if($spec.PSObject.Properties[$name] -and $spec.$name){$candidates.Add([string]$spec.$name)}}}
    if($Item.PSObject.Properties['Settings'] -and $null -ne $Item.Settings){
        foreach($name in @('Path','PhysicalPath','ResolvedCandidate','OriginalPath','PhysicalRoot','ConfigurationFile')){
            $value=Get-WsmWorkloadSettingValue $Item.Settings $name
            if($null -ne $value -and $value -is [string] -and $value){$candidates.Add([string]$value)}
        }
    }
    if($spec -and $spec.PSObject.Properties['RemoteStorage'] -and $spec.RemoteStorage){
        try{
            $endpoint=$spec.RemoteStorage.Source;$relative=ConvertTo-WsmRemoteRelativePath ([string]$endpoint.RelativePath) -AllowRoot
            foreach($alias in @($endpoint.Aliases)){$root=([string]$alias.RootUnc).TrimEnd('\');if($relative){$root=$root+'\'+$relative};$candidates.Add($root)}
        }catch{}
    }
    foreach($candidate in $candidates){if(Test-WsmUncPath $candidate){return (Get-WsmUncResponsibility $candidate $spec)}}
    return $null
}
