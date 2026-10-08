#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-remote-approval-'+[Guid]::NewGuid().ToString('N'))
$root=[IO.Path]::GetFullPath($root)
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root)

        function New-ApprovalRemoteEndpoint {
            param([string]$Name,[string]$Side,[string]$RelativePath,[string]$RootUnc,[string]$ServerIdentity,[string]$ShareIdentity,[string]$RootIdentity,[string]$AliasKind='Direct')
            $alias=[pscustomobject]@{Kind=$AliasKind;RootUnc=$RootUnc;Evidence=('fixture://'+$Name+'/'+$Side+'/alias')}
            if($AliasKind -eq 'DFS'){$alias | Add-Member NoteProperty ReferralEvidence ('fixture://'+$Name+'/'+$Side+'/referral')}
            [pscustomobject]@{
                Provider=[pscustomobject]@{ProviderKind='Fixture';ServerIdentity=$ServerIdentity;ShareIdentity=$ShareIdentity;RootIdentity=$RootIdentity;IdentityEvidence=('fixture://'+$Name+'/'+$Side+'/identity')}
                Aliases=@($alias)
                RelativePath=$RelativePath
            }
        }
        function New-ApprovalRemoteStorage {
            param([string]$Name,[string]$SourceRelative,[string]$TargetRelative,[string]$TargetAlias='\\target-fixture\apps\root',[string]$TargetServer='target-server-id',[string]$TargetShare='target-share-id',[string]$TargetRoot='target-root-id')
            $source=New-ApprovalRemoteEndpoint $Name 'source' $SourceRelative ('\\'+$Name+'-source\data\root') ($Name+'-source-id') 'source-share-id' 'source-root-id'
            $target=New-ApprovalRemoteEndpoint 'target-fixture' 'target' $TargetRelative $TargetAlias $TargetServer $TargetShare $TargetRoot
            $remote=[pscustomobject]@{
                Version=1;Source=$source;Target=$target
                Ownership=[pscustomobject]@{TokenRef=($Name+'-ownership-ref');Owner='Fixture storage owner';Evidence='REMOTE_ENVIRONMENT_CANARY'}
                Consistency=[pscustomobject]@{PlanId=($Name+'-consistency-plan');Revision=3;Method='OwnerFreeze';Writers=@([pscustomobject]@{Identity=($Name+'-writer');Action='Stopped';Evidence=('fixture://'+$Name+'/writer')});FreezeEvidence=('fixture://'+$Name+'/freeze')}
                Artifact=[pscustomobject]@{ArtifactId=($Name+'-artifact');GenerationId=($Name+'-generation-3');ManifestHash=('A'*64);ScopeBindingSHA256='';PlanId=($Name+'-consistency-plan');PlanRevision=3}
            }
            $remote.Artifact.ScopeBindingSHA256=Get-WsmRemoteStorageScopeBindingHash $remote
            $remote
        }
        function Set-ApprovalRemoteBinding($Remote) {
            $Remote.Artifact.ScopeBindingSHA256=Get-WsmRemoteStorageScopeBindingHash $Remote
        }
        function New-ApprovalMigrationSpec($Remote) {
            [pscustomobject]@{
                Adapter='ManualWorkflow';Product='Fixture storage product';Procedure='Reviewed owner procedure';Artifacts=@('independently-reviewed-backup-manifest');BusinessChecks=@('owner verifies staged data')
                Owner='Fixture storage owner';Evidence='fixture://catalog/review';RemoteStorage=$Remote
            }
        }
        function New-ApprovalCase {
            param([string]$Name,[object[]]$Remotes,[string[]]$Decisions)
            $caseRoot=Join-Path $Root $Name
            $workspace=Join-Path $caseRoot 'manager'
            [void][IO.Directory]::CreateDirectory($caseRoot)
            Initialize-WsmWorkspace $workspace | Out-Null
            $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=(Get-WsmHashText ('source-'+$Name));Name=('fixture-source-'+$Name);OS='Fixture Server';Version='10.0.fixture'}
            $items=New-Object 'System.Collections.Generic.List[object]'
            for($index=0;$index -lt $Remotes.Count;$index++){
                $items.Add((New-WsmItem $source.HostId External RemoteStorageItem ($Name+' item '+$index) ($Name+'-item-'+$index) @{Fixture=$true} @() Success Manual))
            }
            $inventory=New-WsmInventory $source 1 $items.ToArray()
            $inventoryPath=Join-Path $caseRoot 'inventory.json'
            [IO.File]::WriteAllText($inventoryPath,($inventory | ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)))
            $catalog=Import-WsmInventory $workspace $inventoryPath (Get-FileHash -LiteralPath $inventoryPath).Hash ('fixture-target-'+$Name)
            for($index=0;$index -lt $Remotes.Count;$index++){
                $spec=New-ApprovalMigrationSpec $Remotes[$index]
                $specPath=Join-Path $caseRoot ('spec-'+$index+'.json')
                [IO.File]::WriteAllText($specPath,($spec | ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)))
                Set-WsmMigrationSpec $workspace $catalog.PairId $items[$index].ItemId $specPath (Get-FileHash -LiteralPath $specPath).Hash $catalog.DecisionRevision
                $catalog=Get-WsmCatalog $workspace $catalog.PairId
            }
            for($index=0;$index -lt $Decisions.Count;$index++){
                $reason='reviewed fixture inclusion';if($Decisions[$index] -eq 'Exclude'){$reason='overlapping scope intentionally excluded'}
                Set-WsmDecision $workspace $catalog.PairId @($items[$index].ItemId) $Decisions[$index] $reason $catalog.DecisionRevision | Out-Null
                $catalog=Get-WsmCatalog $workspace $catalog.PairId
            }
            $targetIdentity=[pscustomobject]@{SchemaVersion=1;ToolVersion='0.3.0';Kind='TargetIdentity';HostId=[Guid]::NewGuid().ToString();Fingerprint=(Get-WsmHashText ('target-'+$Name));Name=('fixture-target-'+$Name)}
            $identityPath=Join-Path $caseRoot 'target-identity.json'
            [IO.File]::WriteAllText($identityPath,($targetIdentity | ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
            [pscustomobject]@{Root=$caseRoot;Workspace=$workspace;PairId=$catalog.PairId;Items=$items.ToArray();TargetIdentityPath=$identityPath}
        }
        function Assert-ApprovalBlocked([scriptblock]$Action,[string]$Name) {
            $blocked=$false;try{& $Action | Out-Null}catch{$blocked=$true}
            if(-not $blocked){throw ('Manager approval accepted '+$Name+'.')}
        }

        $included=New-ApprovalRemoteStorage 'approve-a' 'source-a' 'tenant-a'
        $disjoint=New-ApprovalRemoteStorage 'approve-b' 'source-b' 'tenant-b'
        $excludedOverlap=New-ApprovalRemoteStorage 'exclude-overlap' 'SOURCE-A\nested' 'TENANT-A\nested'
        $excludedOverlap.Source.Provider.ServerIdentity=$included.Source.Provider.ServerIdentity
        $excludedOverlap.Source.Provider.ShareIdentity=$included.Source.Provider.ShareIdentity
        $excludedOverlap.Source.Provider.RootIdentity=$included.Source.Provider.RootIdentity
        $excludedOverlap.Source.Aliases[0].RootUnc='\\different-source-alias\data\root'
        $excludedOverlap.Target.Provider.ServerIdentity=$included.Target.Provider.ServerIdentity
        $excludedOverlap.Target.Provider.ShareIdentity=$included.Target.Provider.ShareIdentity
        $excludedOverlap.Target.Provider.RootIdentity=$included.Target.Provider.RootIdentity
        Set-ApprovalRemoteBinding $excludedOverlap

        $positive=New-ApprovalCase 'approved' @($included,$disjoint,$excludedOverlap) @('Include','Include','Exclude')
        $positivePlanPath=Join-Path $positive.Root 'approved-plan.json'
        $approval=Approve-WsmMigrationPlan $positive.Workspace $positive.PairId $positive.TargetIdentityPath (Get-FileHash -LiteralPath $positive.TargetIdentityPath).Hash $positivePlanPath (Get-WsmCatalog $positive.Workspace $positive.PairId).DecisionRevision 'ISOLATED-PILOT'
        $plan=& $module {param($Path,$Hash) Read-WsmMigrationPlan $Path $Hash} $positivePlanPath $approval.SHA256
        if($plan.Kind -cne 'MigrationPlan' -or @($plan.Items | Where-Object Decision -EQ Include).Count -ne 2 -or @($plan.Items | Where-Object Decision -EQ Exclude).Count -ne 1){throw 'Manager approve/read did not preserve the included and excluded remote items.'}

        $reportPath=Join-Path $positive.Root 'remote-report.html'
        Export-WsmReport $positive.Workspace $positive.PairId $reportPath
        $reportText=[IO.File]::ReadAllText($reportPath)+[IO.File]::ReadAllText($reportPath+'.txt')
        foreach($marker in @('\\target-fixture\apps\root','\\approve-a-source\data\root','ownership-ref','REMOTE_ENVIRONMENT_CANARY','TokenRef')){if($reportText.IndexOf($marker,[StringComparison]::OrdinalIgnoreCase) -ge 0){throw ('Manager report leaked remote storage value: '+$marker)}}

        $sourceLeft=New-ApprovalRemoteStorage 'source-overlap-a' 'root\branch' 'tenant-a'
        $sourceRight=New-ApprovalRemoteStorage 'source-overlap-b' 'ROOT\BRANCH\child' 'tenant-b'
        $sourceRight.Source.Provider.ServerIdentity=$sourceLeft.Source.Provider.ServerIdentity
        $sourceRight.Source.Provider.ShareIdentity=$sourceLeft.Source.Provider.ShareIdentity
        $sourceRight.Source.Provider.RootIdentity=$sourceLeft.Source.Provider.RootIdentity
        $sourceRight.Source.Aliases[0].RootUnc='\\other-source-alias\data\root'
        Set-ApprovalRemoteBinding $sourceRight
        $sourceCase=New-ApprovalCase 'source-conflict' @($sourceLeft,$sourceRight) @('Include','Include')
        Assert-ApprovalBlocked {Approve-WsmMigrationPlan $sourceCase.Workspace $sourceCase.PairId $sourceCase.TargetIdentityPath (Get-FileHash -LiteralPath $sourceCase.TargetIdentityPath).Hash (Join-Path $sourceCase.Root 'plan.json') (Get-WsmCatalog $sourceCase.Workspace $sourceCase.PairId).DecisionRevision 'ISOLATED-PILOT'} 'cross-item source relative-path overlap'

        $targetLeft=New-ApprovalRemoteStorage 'target-overlap-a' 'source-a' 'tenant-root'
        $targetRight=New-ApprovalRemoteStorage 'target-overlap-b' 'source-b' 'TENANT-ROOT\nested'
        $targetRight.Target.Aliases[0].RootUnc='\\another-target-alias\apps\root'
        Set-ApprovalRemoteBinding $targetRight
        $targetCase=New-ApprovalCase 'target-conflict' @($targetLeft,$targetRight) @('Include','Include')
        Assert-ApprovalBlocked {Approve-WsmMigrationPlan $targetCase.Workspace $targetCase.PairId $targetCase.TargetIdentityPath (Get-FileHash -LiteralPath $targetCase.TargetIdentityPath).Hash (Join-Path $targetCase.Root 'plan.json') (Get-WsmCatalog $targetCase.Workspace $targetCase.PairId).DecisionRevision 'ISOLATED-PILOT'} 'cross-item target relative-path overlap through a distinct alias'

        $dfsLeft=New-ApprovalRemoteStorage 'dfs-overlap-a' 'source-a' 'tenant-a'
        $dfsRight=New-ApprovalRemoteStorage 'dfs-overlap-b' 'source-b' 'tenant-a\nested'
        foreach($remote in @($dfsLeft,$dfsRight)){
            $remote.Target.Aliases[0].Kind='DFS'
            $remote.Target.Aliases[0].RootUnc='\\domain-fixture\namespace\apps'
            $remote.Target.Aliases[0] | Add-Member NoteProperty ReferralEvidence ('fixture://'+$remote.Artifact.ArtifactId+'/referral') -Force
            $remote.Target.Provider.ServerIdentity+=('-'+$remote.Artifact.ArtifactId)
            $remote.Target.Provider.ShareIdentity+=('-'+$remote.Artifact.ArtifactId)
            $remote.Target.Provider.RootIdentity+=('-'+$remote.Artifact.ArtifactId)
            Set-ApprovalRemoteBinding $remote
        }
        $dfsCase=New-ApprovalCase 'dfs-conflict' @($dfsLeft,$dfsRight) @('Include','Include')
        Assert-ApprovalBlocked {Approve-WsmMigrationPlan $dfsCase.Workspace $dfsCase.PairId $dfsCase.TargetIdentityPath (Get-FileHash -LiteralPath $dfsCase.TargetIdentityPath).Hash (Join-Path $dfsCase.Root 'plan.json') (Get-WsmCatalog $dfsCase.Workspace $dfsCase.PairId).DecisionRevision 'ISOLATED-PILOT'} 'cross-item overlapping DFS alias paths'

        $fileScope=[pscustomobject]@{Adapter='FileScope';SourcePath='\\nas-fixture\share\root';TargetPath='C:\fixture-target';ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';ConflictPolicy='Block';Owner='Fixture owner';Evidence='fixture evidence';BusinessChecks=@('fixture read')}
        $fileScopeBlocked=$false;try{Assert-WsmMigrationSpec $fileScope}catch{$fileScopeBlocked=($_.Exception.Message -match 'UNC/DFS/NAS scope')}
        if(-not $fileScopeBlocked){throw 'Generic FileScope did not reject UNC/DFS/NAS scopes with the dedicated-provider contract message.'}

        Write-Host 'PASS: real manager catalog remote scope approve/read, excluded overlap, source/target/DFS collision rejection, generic FileScope UNC rejection, and report redaction. Fixture evidence is not provider qualification.'
    } $root
} finally {
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $ownedRoot=[IO.Path]::GetFullPath($root)
    $expectedPrefix=$tempRoot+'\'
    $leaf=[IO.Path]::GetFileName($ownedRoot)
    $ownedParent=[IO.Path]::GetDirectoryName($ownedRoot).TrimEnd('\')
    if(-not $ownedRoot.StartsWith($expectedPrefix,[StringComparison]::OrdinalIgnoreCase) -or -not $ownedParent.Equals($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or $leaf -notmatch '^wsm-remote-approval-[a-f0-9]{32}$'){
        throw 'Test cleanup refused a path outside its exact unique temporary root.'
    }
    if([IO.Directory]::Exists($ownedRoot)){Remove-Item -LiteralPath $ownedRoot -Recurse -Force}
}
