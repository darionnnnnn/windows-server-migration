#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$contractPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\RemoteStorageContracts.ps1'))
& $module {
    param($ContractPath)
    . $ContractPath

    function New-TestRemoteEndpoint {
        param([string]$Name,[string]$Side,[string]$RelativePath,[string]$RootUnc,[string]$ShareIdentity,[string]$RootIdentity)
        [pscustomobject]@{
            Provider=[pscustomobject]@{ProviderKind='SMB fixture provider';ServerIdentity=($Name+'-server-id');ShareIdentity=$ShareIdentity;RootIdentity=$RootIdentity;IdentityEvidence=('evidence://'+$Name+'/'+$Side+'/provider')}
            Aliases=@([pscustomobject]@{Kind='Direct';RootUnc=$RootUnc;Evidence=('evidence://'+$Name+'/'+$Side+'/alias')})
            RelativePath=$RelativePath
        }
    }
    function New-TestRemoteStorage {
        param([string]$Name,[string]$SourceRelative='appA',[string]$TargetRelative='appA',[string]$TargetRoot='\\target-fixture\apps\root',[string]$TargetShare='target-share-id',[string]$TargetIdentity='target-root-id')
        $source=New-TestRemoteEndpoint $Name 'source' $SourceRelative ('\\'+$Name+'-source\data\root') 'source-share-id' 'source-root-id'
        $target=New-TestRemoteEndpoint 'target-fixture' 'target' $TargetRelative $TargetRoot $TargetShare $TargetIdentity
        $scopeBinding=Get-WsmRemoteStorageScopeBindingHash ([pscustomobject]@{Source=$source;Target=$target})
        [pscustomobject]@{
            Version=1
            Source=$source
            Target=$target
            Ownership=[pscustomobject]@{TokenRef=($Name+'-ownership-ref');Owner='Storage owner';Evidence=('evidence://'+$Name+'/ownership')}
            Consistency=[pscustomobject]@{PlanId=($Name+'-consistency-plan');Revision=3;Method='OwnerFreeze';Writers=@([pscustomobject]@{Identity=($Name+'-writer');Action='Stopped';Evidence=('evidence://'+$Name+'/writer')});FreezeEvidence=('evidence://'+$Name+'/freeze')}
            Artifact=[pscustomobject]@{ArtifactId=($Name+'-artifact');GenerationId=($Name+'-generation-3');ManifestHash=('A'*64);ScopeBindingSHA256=$scopeBinding;PlanId=($Name+'-consistency-plan');PlanRevision=3}
        }
    }
    function New-TestRemoteItem {
        param([string]$Id,$Remote,[string]$Decision='Include')
        [pscustomobject]@{ItemId=$Id;Decision=$Decision;MigrationSpec=[pscustomobject]@{Adapter='ManualWorkflow';Owner='Storage owner';RemoteStorage=$Remote}}
    }
    function Assert-TestRemoteBlocked([scriptblock]$Action,[string]$Name) {
        $blocked=$false;try{& $Action}catch{$blocked=$true}
        if(-not $blocked){throw ('Remote storage contract accepted '+$Name+'.')}
    }

    $base=New-TestRemoteStorage 'item-a'
    [void](Assert-WsmRemoteStorageContract $base 'Storage owner')
    $base.Source.Aliases+=@([pscustomobject]@{Kind='DFS';RootUnc='\\domain-fixture\namespace\apps';Evidence='evidence://item-a/source/dfs-alias';ReferralEvidence='evidence://item-a/source/referral'})
    [void](Assert-WsmRemoteStorageContract $base 'Storage owner')
    $second=New-TestRemoteStorage 'item-b' 'appB' 'appB'
    $second.Source.Aliases[0].RootUnc='\\other-source\data\root'
    $validScopes=Assert-WsmRemoteStorageScopes @((New-TestRemoteItem 'a'*64 $base),(New-TestRemoteItem 'b'*64 $second))
    if(-not $validScopes.Valid){throw 'Disjoint reviewed remote scopes did not pass.'}

    $sameIds=New-TestRemoteStorage 'item-c' 'other-source' 'appa' '\\different-target-alias\different-share\root' 'target-share-id' 'target-root-id'
    Assert-TestRemoteBlocked {Assert-WsmRemoteStorageScopes @((New-TestRemoteItem ('a'*64) $base),(New-TestRemoteItem ('c'*64) $sameIds))} 'same canonical storage root/path through distinct UNC aliases'

    $caseOverlap=New-TestRemoteStorage 'item-d' 'source-c' 'APPA\nested' '\\target-fixture\apps\root' 'target-share-id' 'target-root-id'
    Assert-TestRemoteBlocked {Assert-WsmRemoteStorageScopes @((New-TestRemoteItem ('a'*64) $base),(New-TestRemoteItem ('d'*64) $caseOverlap))} 'case-insensitive ancestor scope overlap'

    $nestedShare=New-TestRemoteStorage 'item-e' 'source-e' 'child' '\\target-fixture\apps\root\appA' 'nested-share-id' 'nested-root-id'
    Assert-TestRemoteBlocked {Assert-WsmRemoteStorageScopes @((New-TestRemoteItem ('a'*64) $base),(New-TestRemoteItem ('e'*64) $nestedShare))} 'nested UNC share path overlap'

    $conflictingRoot=New-TestRemoteStorage 'item-e2' 'source-e2' 'appB' '\\different-target-alias\different-share\root' 'target-share-id' 'another-target-root-id'
    Assert-TestRemoteBlocked {Assert-WsmRemoteStorageScopes @((New-TestRemoteItem ('a'*64) $base),(New-TestRemoteItem ('e2'*32) $conflictingRoot))} 'ambiguous roots under one canonical share identity'

    $missingReferral=New-TestRemoteStorage 'item-f'
    $missingReferral.Source.Aliases[0]=[pscustomobject]@{Kind='DFS';RootUnc='\\domain-fixture\namespace\root';Evidence='evidence://item-f/alias';ReferralEvidence=''}
    Assert-TestRemoteBlocked {Assert-WsmRemoteStorageContract $missingReferral 'Storage owner'} 'DFS alias without referral evidence'

    $badRelative=New-TestRemoteStorage 'item-g'
    $badRelative.Target.RelativePath='..\escape'
    Assert-TestRemoteBlocked {Assert-WsmRemoteStorageContract $badRelative 'Storage owner'} 'relative path traversal'

    $badAlias=New-TestRemoteStorage 'item-h'
    $badAlias.Source.Aliases[0].RootUnc='\\source\share\root\..\other'
    Assert-TestRemoteBlocked {Assert-WsmRemoteStorageContract $badAlias 'Storage owner'} 'UNC alias traversal'
    $overlappingAliases=New-TestRemoteStorage 'item-h2'
    $overlappingAliases.Source.Aliases+=@([pscustomobject]@{Kind='Direct';RootUnc='\\item-h2-source\data\root\child';Evidence='evidence://item-h2/nested-alias'})
    Assert-TestRemoteBlocked {Assert-WsmRemoteStorageContract $overlappingAliases 'Storage owner'} 'overlapping alias roots with ambiguous provider root mapping'
    $caseAlias=New-TestRemoteStorage 'item-h3'
    $caseAlias.Target.Aliases+=@([pscustomobject]@{Kind='Direct';RootUnc='\\TARGET-FIXTURE\APPS\ROOT';Evidence='evidence://item-h3/case-alias'})
    Assert-TestRemoteBlocked {Assert-WsmRemoteStorageContract $caseAlias 'Storage owner'} 'case-duplicate UNC aliases'

    $wrongOwner=New-TestRemoteStorage 'item-i'
    $wrongOwner.Ownership.Owner='Different owner'
    Assert-TestRemoteBlocked {Assert-WsmRemoteStorageContract $wrongOwner 'Storage owner'} 'ownership owner mismatch'

    $badArtifact=New-TestRemoteStorage 'item-j'
    $badArtifact.Artifact.PlanRevision=2
    Assert-TestRemoteBlocked {Assert-WsmRemoteStorageContract $badArtifact 'Storage owner'} 'artifact from a stale consistency revision'
    $wrongArtifactScope=New-TestRemoteStorage 'item-j1'
    $wrongArtifactScope.Target.RelativePath='different-scope'
    Assert-TestRemoteBlocked {Assert-WsmRemoteStorageContract $wrongArtifactScope 'Storage owner'} 'artifact bound to another remote scope'
    $fractionalRevision=New-TestRemoteStorage 'item-j2'
    $fractionalRevision.Consistency.Revision=3.5
    Assert-TestRemoteBlocked {Assert-WsmRemoteStorageContract $fractionalRevision 'Storage owner'} 'fractional consistency plan revision'

    $missingWriter=New-TestRemoteStorage 'item-k'
    $missingWriter.Consistency.Writers=@()
    Assert-TestRemoteBlocked {Assert-WsmRemoteStorageContract $missingWriter 'Storage owner'} 'consistency plan without declared writers'

    $badAction=New-TestRemoteStorage 'item-l'
    $badAction.Consistency.Method='ImmutableSnapshot'
    Assert-TestRemoteBlocked {Assert-WsmRemoteStorageContract $badAction 'Storage owner'} 'snapshot plan without writer snapshot coverage'

    $summary=Get-WsmRemoteStorageSummary @((New-TestRemoteItem ('a'*64) $base))
    if(@($summary).Count -ne 1 -or -not $summary[0].GenerationBound){throw 'Remote report summary omitted the artifact generation binding.'}
    $summaryJson=$summary | ConvertTo-Json -Depth 8 -Compress
    if($summaryJson -match 'target-fixture|ownership-ref|namespace\\apps'){throw 'Remote report summary disclosed UNC aliases or ownership token references.'}

    # A bounded large fixture exercises the sorted interval passes without
    # relying on timing thresholds that vary across PowerShell hosts.
    $bulkItems=New-Object 'System.Collections.Generic.List[object]'
    for($index=0;$index -lt 2000;$index++){
        $suffix=$index.ToString('D4',[Globalization.CultureInfo]::InvariantCulture)
        $remote=New-TestRemoteStorage ('scale-'+$suffix) 'appA' ('tenant-'+$suffix)
        [void]$bulkItems.Add((New-TestRemoteItem ((Get-WsmHashText ('remote-scale-'+$suffix))) $remote))
    }
    $bulkScopes=Assert-WsmRemoteStorageScopes $bulkItems.ToArray()
    if(-not $bulkScopes.Valid -or $bulkScopes.ScopeCount -ne 4000){throw 'Large disjoint remote scope fixture did not pass with the expected endpoint count.'}
    $lastRemote=New-TestRemoteStorage 'scale-overlap' 'appA' 'tenant-1999\nested'
    [void]$bulkItems.Add((New-TestRemoteItem (Get-WsmHashText 'remote-scale-overlap') $lastRemote))
    Assert-TestRemoteBlocked {Assert-WsmRemoteStorageScopes $bulkItems.ToArray()} 'overlap in the final claim of a large remote scope fixture'
    Write-Host 'PASS: remote provider identity, direct/DFS alias evidence, exact relative scope, ownership, writer consistency, artifact generation, sorted path overlap, scale fixture and safe summary contracts. Provider identity still requires independent owner/provider evidence.'
} $contractPath
