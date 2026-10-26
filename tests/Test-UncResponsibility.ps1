#requires -Version 5.1
# Q2: UNC 路徑的責任標示（沿用既有外部共享／另行遷移）。
# 涵蓋：分類（無證據、契約通過、契約不完整、範圍不涵蓋）、UNC 不會被改寫成本機路徑（草稿與核准檢查實際呼叫）、
# 三處投影（審閱路徑顯示、一鍵備份結果集與離線報告、還原預覽列）帶分類欄位與字樣、路徑字串安全化。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking 3>$null
$root=Join-Path $env:TEMP ('wsm-q2-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root)
        $script:ToolVersion='fixture'
        $check={param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}

        function New-TestRemoteEndpoint {
            param([string]$Name,[string]$Side,[string]$RelativePath,[string]$RootUnc,[string]$ShareIdentity,[string]$RootIdentity)
            [pscustomobject]@{
                Provider=[pscustomobject]@{ProviderKind='SMB fixture provider';ServerIdentity=($Name+'-server-id');ShareIdentity=$ShareIdentity;RootIdentity=$RootIdentity;IdentityEvidence=('evidence://'+$Name+'/'+$Side+'/provider')}
                Aliases=@([pscustomobject]@{Kind='Direct';RootUnc=$RootUnc;Evidence=('evidence://'+$Name+'/'+$Side+'/alias')})
                RelativePath=$RelativePath
            }
        }
        function New-TestRemoteStorage {
            param([string]$Name)
            $source=New-TestRemoteEndpoint $Name 'source' 'appA' ('\\'+$Name+'-source\data\root') 'source-share-id' 'source-root-id'
            $target=New-TestRemoteEndpoint 'target-fixture' 'target' 'appA' '\\target-fixture\apps\root' 'target-share-id' 'target-root-id'
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
        function New-TestSpec($Remote,[string]$Adapter='ManualWorkflow',[string]$Owner='Storage owner') {
            [pscustomobject]@{Adapter=$Adapter;Owner=$Owner;Evidence='evidence://spec';Product='Remote storage';Procedure='Owner-managed procedure';Artifacts=@();BusinessChecks=@('check');RemoteStorage=$Remote}
        }
        function Copy-TestObject($Value) {ConvertFrom-Json (ConvertTo-Json -InputObject $Value -Depth 20)}

        $remote=New-TestRemoteStorage 'item-a'
        $goodSpec=New-TestSpec $remote
        $srcInside='\\item-a-source\data\root\appA\data\file.cfg'
        $hostile='\\fs1\share\<script>alert(1)<x>\data'

        # ---- 1. 分類
        & $check ($null -eq (Get-WsmUncResponsibility 'C:\Data\app')) 'A local path has no UNC responsibility.'
        foreach($notUnc in @('\\?\C:\x','\\.\pipe\x','\\srv','','relative\path','//srv/share/x')){& $check ($null -eq (Get-WsmUncResponsibility $notUnc)) ('Not a UNC share path: '+$notUnc)}
        & $check ($null -eq (Get-WsmUncResponsibility $null)) 'A null path has no UNC responsibility.'
        $plain=Get-WsmUncResponsibility '\\fs1\data\app'
        & $check ($plain.Responsibility -ceq 'ExternalShareReuse' -and -not $plain.Evidence -and $plain.EvidenceText -ceq '無') 'Without evidence a UNC path must be ExternalShareReuse with no evidence.'
        & $check ($plain.Reason -and $plain.NextStep -and $plain.Reason -match '[\u4e00-\u9fff]' -and $plain.NextStep -match '[\u4e00-\u9fff]') 'The classification needs a Chinese reason and next step.'
        & $check ($plain.BackupText -ceq '沿用外部共享，未備份' -and $plain.Label -ceq '沿用外部共享' -and $plain.AutomaticCopy -eq $false -and $plain.RewrittenToLocal -eq $false) 'ExternalShareReuse texts, no automatic copy and no local rewrite.'
        $noSpec=Get-WsmUncResponsibility '\\fs1\data\app' ([pscustomobject]@{Adapter='ManualWorkflow';Owner='x'})
        & $check ($noSpec.Responsibility -ceq 'ExternalShareReuse') 'A spec without RemoteStorage stays ExternalShareReuse.'
        foreach($insidePath in @($srcInside,'\\item-a-source\data\root\appA','\\target-fixture\apps\root\appA\x')){
            $separate=Get-WsmUncResponsibility $insidePath $goodSpec
            & $check ($separate.Responsibility -ceq 'SeparateMigration' -and $separate.Evidence -and $separate.EvidenceText -ceq '有') ('A verified RemoteStorage contract covering the path must be SeparateMigration: '+$insidePath)
            & $check ($separate.BackupText -ceq '另行遷移，見核准' -and $separate.AutomaticCopy -eq $false -and $separate.RewrittenToLocal -eq $false -and $separate.NextStep -match '另行核准') 'SeparateMigration texts still never copy automatically.'
        }
        foreach($outside in @('\\item-a-source\data\root\appB','\\item-a-source\data\root\appAB\x','\\item-a-source\data\root','\\other\data\root\appA')){
            $uncovered=Get-WsmUncResponsibility $outside $goodSpec
            & $check ($uncovered.Responsibility -ceq 'ExternalShareReuse' -and -not $uncovered.Evidence -and $uncovered.Reason -match '不涵蓋') ('A valid contract that does not cover the path falls back: '+$outside)
        }
        $broken=@(
            @{Name='missing ownership';Spec={$r=Copy-TestObject $remote;$r.PSObject.Properties.Remove('Ownership');New-TestSpec $r}},
            @{Name='tampered scope binding';Spec={$r=Copy-TestObject $remote;$r.Artifact.ScopeBindingSHA256=('f'*64);New-TestSpec $r}},
            @{Name='no writers';Spec={$r=Copy-TestObject $remote;$r.Consistency.Writers=@();New-TestSpec $r}},
            @{Name='unsupported version';Spec={$r=Copy-TestObject $remote;$r.Version=2;New-TestSpec $r}},
            @{Name='owner mismatch';Spec={New-TestSpec (Copy-TestObject $remote) 'ManualWorkflow' 'Someone else'}},
            @{Name='wrong adapter';Spec={New-TestSpec (Copy-TestObject $remote) 'FileScope'}},
            @{Name='empty contract';Spec={New-TestSpec ([pscustomobject]@{Version=1})}}
        )
        foreach($case in $broken){
            $badSpec=& $case.Spec
            $result=Get-WsmUncResponsibility $srcInside $badSpec
            & $check ($result.Responsibility -ceq 'ExternalShareReuse' -and -not $result.Evidence) ('An invalid contract must fall back to ExternalShareReuse: '+$case.Name)
            & $check ($result.Reason -match '未通過驗證' -and $result.NextStep -match '不會複製') ('The fallback must say why and that nothing is copied: '+$case.Name)
        }
        # 項目層級：核准規格、盤點設定與 RemoteStorage 來源別名都要找得到 UNC 路徑。
        $itemSettings=[pscustomobject]@{ItemId='i1';Settings=[pscustomobject]@{Path=$srcInside};MigrationSpec=$goodSpec}
        & $check ((Get-WsmItemUncResponsibility $itemSettings).Responsibility -ceq 'SeparateMigration') 'Item level: Settings.Path with a covering contract.'
        $itemAlias=[pscustomobject]@{ItemId='i2';Settings=[pscustomobject]@{Path='C:\local'};MigrationSpec=$goodSpec}
        & $check ((Get-WsmItemUncResponsibility $itemAlias).Responsibility -ceq 'SeparateMigration') 'Item level: a non-UNC location still finds the RemoteStorage source alias.'
        & $check ($null -eq (Get-WsmItemUncResponsibility ([pscustomobject]@{ItemId='i3';Settings=[pscustomobject]@{Path='C:\local'}}))) 'Item level: no UNC means no classification.'
        & $check ((Get-WsmItemUncResponsibility ([pscustomobject]@{ItemId='i4';Settings=@{OriginalPath='\\fs1\x\y'}})).Responsibility -ceq 'ExternalShareReuse') 'Item level: hashtable settings are read too.'
        # 路徑字串安全化：控制字元可見化，標記字元保留為資料（HTML 由各投影統一跳脫）。
        $evil=Get-WsmUncResponsibility ("\\fs1\sh`r`n\a<script>alert(1)<x> password=abc")
        & $check ($evil.Path -notmatch "[\r\n]" -and $evil.Path -match '\\u000D\\u000A' -and $evil.Path -notmatch 'abc') 'The path is made visible (control characters) and secrets are redacted.'
        Write-Host 'PASS: UNC responsibility classification.'

        # ---- 2. 不改寫成本機
        $catalog=[pscustomobject]@{Items=@()}
        $candidate={param([string]$Original,[string]$Resolved,[string]$Basis,[string]$Mapping)
            $item=[pscustomobject]@{ItemId=('c'*64);Category='Storage';Kind='PathCandidate';Name=$Original;NaturalKey=('candidate:'+$Original);Mapping=$Mapping;Settings=[pscustomobject]@{OriginalPath=$Original;ResolvedCandidate=$Resolved;ResolutionBasis=$Basis;ResolutionVariables=@()}}
            $item
        }
        $uncDraft=Get-WsmMigrationSpecDraft (& $candidate '\\fs1\data\app' '\\fs1\data\app' 'Literal' 'D:\Local\Elsewhere') $catalog
        & $check ($uncDraft.Adapter -ceq 'FileScope' -and $uncDraft.SourcePath -ceq '\\fs1\data\app') 'The UNC draft keeps the UNC source.'
        & $check ($uncDraft.TargetPath -ceq '\\fs1\data\app' -and $uncDraft.TargetPath -notmatch '^[A-Za-z]:') 'A local mapping must not turn a UNC source into a local target path.'
        & $check ((@($uncDraft.BusinessChecks) -join ' ') -match 'UNC' -and (@($uncDraft.BusinessChecks) -join ' ') -match 'never rewritten') 'The draft records the UNC responsibility in its checks.'
        $uncResolved=Get-WsmMigrationSpecDraft (& $candidate '%FILESERVER%\data' '\\fs2\data\app' 'Machine' 'E:\Elsewhere') $catalog
        & $check ($uncResolved.TargetPath -ceq '\\fs2\data\app') 'A UNC resolved candidate also ignores the local mapping.'
        $localDraft=Get-WsmMigrationSpecDraft (& $candidate 'D:\Data\app' 'D:\Data\app' 'Literal' 'E:\Mapped') $catalog
        & $check ($localDraft.TargetPath -ceq 'E:\Mapped' -and -not ((@($localDraft.BusinessChecks) -join ' ') -match 'UNC')) 'A local source still honours its mapping (the guard is UNC-specific).'
        $localNoMap=Get-WsmMigrationSpecDraft (& $candidate 'D:\Data\app' 'D:\Data\app' 'Literal' '') $catalog
        & $check ($localNoMap.TargetPath -ceq 'D:\Data\app') 'A local source without a mapping keeps its own path.'
        # 核准檢查：任何 UNC 來源／目的的 FileScope 規格都不能核准（不論另一端是否為本機）。
        $approve={param($Spec,[string]$Source,[string]$Target)
            $copy=Copy-TestObject $Spec;$copy.Owner='Storage owner';$copy.Evidence='evidence://q2';$copy.SourcePath=$Source;$copy.TargetPath=$Target
            $message='';try{Assert-WsmMigrationSpec $copy}catch{$message=$_.Exception.Message};$message
        }
        $uncSpecDraft=Copy-TestObject $uncDraft
        foreach($pair in @(@('\\fs1\data\app','\\fs1\data\app'),@('\\fs1\data\app','D:\Local\Elsewhere'),@('D:\Data\app','\\fs1\data\app'))){
            $message=& $approve $uncSpecDraft $pair[0] $pair[1]
            & $check ($message -match 'UNC/DFS/NAS scope requires') ('Approval must block any UNC FileScope scope: '+$pair[0]+' -> '+$pair[1]+' ['+$message+']')
        }
        $localMessage=& $approve (Copy-TestObject $localDraft) 'D:\Data\app' 'E:\Mapped'
        & $check ($localMessage -notmatch 'UNC/DFS/NAS') 'A local FileScope is not blocked by the UNC rule.'
        # 工作負載引用對應：UNC 引用不會被對應到本機 FileScope 的目的路徑。
        $scopeItem=[pscustomobject]@{ItemId=('d'*64);Decision='Include';ReviewedBy='tester';ReviewedUtc='2026-10-25T00:00:00Z';NaturalKey='scope:d';MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath='D:\Data\app';TargetPath='E:\Target\app';ExcludedRelativePaths=@();ContentSelection='WholeScope'}}
        $mappingCatalog=[pscustomobject]@{Items=@($scopeItem)}
        $mappingResult=Resolve-WsmWorkloadReferenceMapping $mappingCatalog ([pscustomobject]@{ResolvedPath='\\fs1\data\app\run.exe';RawValue='\\fs1\data\app\run.exe';ReferenceKind='TaskCommand';ConsumerItemId=('e'*64);FieldPointer='/Exec'}) -ExplicitFileScopeItemId ('d'*64)
        & $check ($mappingResult.Status -cne 'Mapped' -and -not $mappingResult.TargetValue) 'A UNC reference must never be mapped to a local FileScope target.'
        $mappingLocal=Resolve-WsmWorkloadReferenceMapping $mappingCatalog ([pscustomobject]@{ResolvedPath='D:\Data\app\run.exe';RawValue='D:\Data\app\run.exe';ReferenceKind='TaskCommand';ConsumerItemId=('e'*64);FieldPointer='/Exec'}) -ExplicitFileScopeItemId ('d'*64)
        & $check ($mappingLocal.Status -ceq 'Mapped' -and $mappingLocal.TargetValue -ceq 'E:\Target\app\run.exe') 'Control: a local reference under the same FileScope is mapped.'
        Write-Host 'PASS: UNC is never rewritten to a local path (draft, approval, workload mapping).'

        # ---- 3a. 審閱：路徑顯示
        $reviewItem={param([string]$Path,$Spec,$Basis)
            $settings=[ordered]@{}
            if($Basis){$settings.OriginalPath=$Path;$settings.ResolvedCandidate=$Path;$settings.ResolutionBasis=$Basis}else{$settings.Path=$Path}
            $item=[pscustomobject]@{ItemId=('a'*64);Name='review item';Kind='PathCandidate';Settings=[pscustomobject]$settings}
            if($Spec){$item|Add-Member NoteProperty MigrationSpec $Spec}
            $item
        }
        $plainDetails=@(Get-WsmWizardFileDetails (& $reviewItem '\\fs1\data\app' $null $null))
        & $check ($plainDetails.Count -eq 1 -and $plainDetails[0].uncResponsibility.Responsibility -ceq 'ExternalShareReuse' -and $plainDetails[0].uncResponsibility.Summary -match '沿用外部共享') 'Review detail rows carry the classification when the item has no path resolution.'
        $separateDetails=@(Get-WsmWizardFileDetails (& $reviewItem $srcInside $goodSpec $null))
        & $check ($separateDetails[0].uncResponsibility.Responsibility -ceq 'SeparateMigration' -and $separateDetails[0].uncResponsibility.Summary -match '另行遷移') 'Review detail rows show SeparateMigration with a verified contract.'
        $resolvedDetails=@(Get-WsmWizardFileDetails (& $reviewItem '\\fs1\data\app' $null 'Literal'))
        & $check ($resolvedDetails[0].resolution.uncResponsibility.Responsibility -ceq 'ExternalShareReuse' -and -not $resolvedDetails[0].PSObject.Properties['uncResponsibility']) 'A resolved path carries the classification inside its resolution view (once).'
        $hostileDetails=@(Get-WsmWizardFileDetails (& $reviewItem $hostile $null 'Literal'))
        & $check ($hostileDetails[0].resolution.uncResponsibility.Path -ceq $hostile) 'Markup in a UNC path stays data (escaping is the renderer job).'
        $localDetails=@(Get-WsmWizardFileDetails (& $reviewItem 'D:\Data\app' $null 'Literal'))
        & $check (-not $localDetails[0].resolution.PSObject.Properties['uncResponsibility'] -and -not $localDetails[0].PSObject.Properties['uncResponsibility']) 'A local path has no UNC responsibility in the review.'
        $c2Row=ConvertTo-WsmWizardPathResolutionRow ([pscustomobject]@{ItemId='x';ItemName='n';ItemKind='ScheduledTask';Resolution=(New-WsmPathResolutionView -Original '\\fs1\data\run.exe' -Resolved '' -Basis 'Unresolved');Injected='SECRET-MUST-NOT-LEAK'})
        & $check ($c2Row.Resolution.uncResponsibility.Responsibility -ceq 'ExternalShareReuse' -and $c2Row.Resolution.uncResponsibility.BackupText -ceq '沿用外部共享，未備份') 'The closed C2 row keeps the classification.'
        & $check ((ConvertTo-Json $c2Row -Depth 8) -notmatch 'SECRET-MUST-NOT-LEAK') 'The closed C2 row drops unexpected fields.'
        Write-Host 'PASS: review path display projection.'

        # ---- 3b. 一鍵備份：結果集與離線報告
        $item={param([string]$Id,[string]$Name,$Spec,[string]$Decision,[string]$Kind='DataRoot',[string]$Path='C:\settings\x')[pscustomobject]@{ItemId=$Id;Name=$Name;Kind=$Kind;Category='Storage';NaturalKey=('key-'+$Id);Settings=[pscustomobject]@{Path=$Path};Decision=$Decision;MigrationSpec=$Spec;Dependencies=@()}}
        $plan=[pscustomobject]@{Items=@(
            (& $item 'unc-excluded' 'UNC excluded' $null 'Exclude' 'DataRoot' $hostile),
            (& $item 'unc-pending' 'UNC pending' $null 'Pending' 'DataRoot' '\\fs9\pending\data'),
            (& $item 'unc-separate' 'UNC separate' $goodSpec 'Include' 'DataRoot' $srcInside),
            (& $item 'unc-bad-contract' 'UNC bad contract' (New-TestSpec ([pscustomobject]@{Version=1})) 'Include' 'DataRoot' $srcInside),
            (& $item 'local-data' 'Local data' ([pscustomobject]@{Adapter='FileScope';SourcePath='D:\scope\C';TransferChannel='C'}) 'Include'),
            (& $item 'site' 'Site with UNC content' ([pscustomobject]@{Adapter='IISSite'}) 'Include' 'IISSite'))}
        $artifacts=@([pscustomobject]@{ItemId='local-data';RelativePath='a.txt';Directory=$false;Data=[pscustomobject]@{Bytes=10}})
        $discovery=[pscustomobject]@{References=@([pscustomobject]@{ConsumerItemId='site';ResourceItemId='';ResolvedPath='\\fs2\web\content';RawValue='\\fs2\web\content'})}
        $rows=@(Get-WsmBackupItemResultRows $plan $null $artifacts $false $discovery)
        $byId=@{};foreach($row in $rows){$byId[[string]$row.ItemId]=$row}
        foreach($id in @('unc-excluded','unc-pending','unc-separate','unc-bad-contract')){& $check ($byId[$id].Status -ceq 'NotBackedUp' -and $byId[$id].Files -eq 0 -and $byId[$id].PSObject.Properties['UncResponsibility']) ('A UNC row is never backed up and carries a classification: '+$id)}
        & $check ($byId['unc-excluded'].ReasonCode -ceq 'Excluded' -and $byId['unc-excluded'].UncResponsibility.Responsibility -ceq 'ExternalShareReuse') 'Excluded UNC row: reason code unchanged, classification attached.'
        & $check ($byId['unc-pending'].UncResponsibility.Responsibility -ceq 'ExternalShareReuse') 'Pending UNC row is ExternalShareReuse.'
        & $check ($byId['unc-separate'].UncResponsibility.Responsibility -ceq 'SeparateMigration' -and $byId['unc-separate'].ReasonCode -ceq 'ManualHandling') 'A verified RemoteStorage item is SeparateMigration and still not backed up by the one-click backup.'
        & $check ($byId['unc-bad-contract'].UncResponsibility.Responsibility -ceq 'ExternalShareReuse' -and $byId['unc-bad-contract'].UncResponsibility.Reason -match '未通過驗證') 'An incomplete contract falls back with its reason.'
        & $check ($byId['site'].PSObject.Properties['UncResponsibility'] -and $byId['site'].UncResponsibility.Responsibility -ceq 'ExternalShareReuse' -and $byId['site'].UncResponsibility.Path -ceq '\\fs2\web\content') 'A UNC content reference of a workload is classified too.'
        & $check ($byId['local-data'].Status -ceq 'BackedUp' -and -not $byId['local-data'].PSObject.Properties['UncResponsibility']) 'A local backed up row has no UNC classification.'
        $software=[pscustomobject]@{SoftwareRows=@();FeatureRows=@();CoverageGaps=@()}
        $meta=[pscustomobject]@{PairId='p';AttemptId='a';PlanHash=('1'*64);ManifestHash=('2'*64);InventorySource='TrustedInventory';Software=$software}
        $resultsPath=Join-Path $Root 'results.json'
        $export=Export-WsmBackupItemResults $resultsPath $rows $meta
        $doc=Read-WsmJson $resultsPath
        $savedById=@{};foreach($row in @($doc.Rows)){$savedById[[string]$row.ItemId]=$row}
        & $check ($savedById['unc-excluded'].UncResponsibility.BackupText -ceq '沿用外部共享，未備份' -and $savedById['unc-separate'].UncResponsibility.BackupText -ceq '另行遷移，見核准') 'The saved result set keeps the classification of every UNC row.'
        $reportPath=Join-Path $Root 'report.html'
        $report=Export-WsmBackupOfflineReport $resultsPath $export.SHA256 $reportPath
        $html=[IO.File]::ReadAllText($report.Path,[Text.Encoding]::UTF8)
        & $check ($html.Contains('沿用外部共享，未備份') -and $html.Contains('另行遷移，見核准')) 'The offline report names both responsibilities in the not-backed-up table.'
        & $check ($html.Contains('由共享的擁有者協調保留共享名稱')) 'The offline report shows the responsibility next step.'
        & $check (-not $html.Contains('<script>alert(1)') -and $html.Contains('&lt;script&gt;alert(1)')) 'UNC path markup is HTML-escaped in the offline report.'
        $pendingSection=$html.Substring($html.IndexOf('id="pending"'))
        & $check ($pendingSection.Contains('沿用外部共享，未備份') -and $pendingSection.Contains('另行遷移，見核准')) 'The classification is in the not-backed-up section, not only elsewhere.'
        Write-Host 'PASS: one-click backup result set and offline report.'

        # ---- 3c. 還原預覽列
        $uncPlanItem=[pscustomobject]@{ItemId='unc-separate';Name='UNC separate';Dependencies=@();Settings=[pscustomobject]@{Path=$srcInside};MigrationSpec=$goodSpec}
        $localPlanItem=[pscustomobject]@{ItemId='local-data';Name='Local';Dependencies=@();Settings=[pscustomobject]@{Path='D:\x'};MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath='D:\x';TargetPath='D:\x'}}
        $previewRow=[pscustomobject]@{ItemId='unc-separate';Adapter='ManualWorkflow';Action='RestoreNow';Status='Ready';Reason=''}
        Add-WsmAssistivePreviewDisplayFields $previewRow $uncPlanItem @{} @{'unc-separate'=$true} @{'unc-separate'=$uncPlanItem} @{}
        & $check ($previewRow.PSObject.Properties['UncResponsibility'] -and $previewRow.UncResponsibility.Responsibility -ceq 'SeparateMigration') 'The restore preview row for a UNC item carries the classification.'
        $localRow=[pscustomobject]@{ItemId='local-data';Adapter='FileScope';Action='RestoreNow';Status='Ready';Reason=''}
        Add-WsmAssistivePreviewDisplayFields $localRow $localPlanItem @{} @{'local-data'=$true} @{'local-data'=$localPlanItem} @{}
        & $check (-not $localRow.PSObject.Properties['UncResponsibility']) 'A local restore preview row has no UNC classification.'
        $stripped=Remove-WsmAssistivePreviewDisplayFields $previewRow
        & $check (-not $stripped.PSObject.Properties['UncResponsibility'] -and -not $stripped.PSObject.Properties['FileCount']) 'The classification is display-only: it never enters the preview hash.'
        $externalRow=[pscustomobject]@{ItemId='ext';Adapter='ManualWorkflow';Action='DeferredBySelection';Status='Deferred';Reason=''}
        Add-WsmAssistivePreviewDisplayFields $externalRow ([pscustomobject]@{ItemId='ext';Dependencies=@();Settings=[pscustomobject]@{Path='\\fs3\ext\data'};MigrationSpec=(New-TestSpec $null)}) @{} @{} @{} @{}
        & $check ($externalRow.UncResponsibility.Responsibility -ceq 'ExternalShareReuse') 'A UNC item without a contract is ExternalShareReuse in the preview.'
        $html=ConvertTo-WsmWizardHtmlValue ([pscustomobject]@{Kind='RestorePreview';Rows=@($previewRow,$externalRow);Secret='SECRET-MUST-NOT-LEAK'})
        $htmlRow=@($html.Rows)[0]
        & $check ($htmlRow.UncResponsibility.Responsibility -ceq 'SeparateMigration' -and $htmlRow.UncResponsibility.Summary -ceq '另行遷移，需另行核准' -and $htmlRow.UncResponsibility.EvidenceText -ceq '有') 'The HTML runtime projection keeps the nested classification fields.'
        & $check ((ConvertTo-Json $html -Depth 10) -notmatch 'SECRET-MUST-NOT-LEAK') 'The HTML runtime projection still drops unknown fields.'
        Write-Host 'PASS: restore preview rows and HTML projection.'

        # ---- 4. Q2b（PLAN 17.129）：UNC 來源的項目不接受本機 Mapping（Set-WsmMapping 依 Get-WsmItemUncResponsibility 拒絕，並給出下一步）
        $script:ToolVersion='0.4.0'  # 本節用真實目錄／匯入流程，需要與模組一致的工具版本
        $q2bWorkspace=Join-Path $Root 'q2b-manager';[void](Initialize-WsmWorkspace $q2bWorkspace)
        $q2bSource=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('b'*64);Name='old-q2b'}
        $q2bItems=@((New-WsmItem $q2bSource.HostId Storage PathCandidate 'unc-data' '\\fs1\data\app' @{Path='\\fs1\data\app'}),(New-WsmItem $q2bSource.HostId Storage PathCandidate 'local-data' 'D:\Data\app' @{Path='D:\Data\app'}))
        $q2bFile=Join-Path $Root 'q2b-inventory.json';[IO.File]::WriteAllText($q2bFile,((New-WsmInventory $q2bSource 1 $q2bItems)|ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)))
        $q2bPair=(Import-WsmInventory $q2bWorkspace $q2bFile (Get-FileHash -LiteralPath $q2bFile -Algorithm SHA256).Hash 'new-q2b').PairId
        $q2bUncId=$q2bItems[0].ItemId;$q2bLocalId=$q2bItems[1].ItemId
        $q2bRev={(Get-WsmCatalog $q2bWorkspace $q2bPair).DecisionRevision}
        $q2bRow={param($Id)@((Get-WsmCatalog $q2bWorkspace $q2bPair).Items|Where-Object ItemId -CEQ $Id)[0]}
        $before=& $q2bRev
        $message='';try{Set-WsmMapping $q2bWorkspace $q2bPair $q2bUncId 'E:\Mapped' $before}catch{$message=[string]$_.Exception.Message}
        & $check ($message -match 'UNC' -and $message -match '沿用外部共享' -and $message -match '不會把它改成本機路徑') ('A UNC item must not accept a local mapping and must say what to do next: ['+$message+']')
        & $check ((& $q2bRev) -eq $before -and -not (& $q2bRow $q2bUncId).Mapping) 'A rejected UNC mapping must leave the catalog untouched.'
        Set-WsmMapping $q2bWorkspace $q2bPair $q2bLocalId 'E:\Mapped' (& $q2bRev)
        & $check ((& $q2bRow $q2bLocalId).Mapping -ceq 'E:\Mapped') 'Control: a local item still accepts a local mapping.'
        Set-WsmMapping $q2bWorkspace $q2bPair $q2bUncId 'DOMAIN\Svc' (& $q2bRev) -Type Account
        & $check ((& $q2bRow $q2bUncId).AccountMapping -ceq 'DOMAIN\Svc') 'An account mapping is not a local path mapping and stays allowed for a UNC item.'
        Set-WsmMapping $q2bWorkspace $q2bPair $q2bUncId '' (& $q2bRev)
        & $check (-not (& $q2bRow $q2bUncId).Mapping) 'Clearing a mapping on a UNC item stays allowed.'
        Write-Host 'PASS: Q2b UNC item rejects a local mapping.'
        $script:ToolVersion='fixture'

        # ---- 5. Q2c（PLAN 17.129）：草稿的 TransferChannel 依 Get-WsmUncResponsibility 決定，不再把 UNC 來源標成 NonC
        $assistiveCatalog=[pscustomobject]@{Items=@();Assistive=[pscustomobject]@{ContractVersion=0}}
        $uncAssistive=Get-WsmMigrationSpecDraft (& $candidate '\\fs1\data\app' '\\fs1\data\app' 'Literal' 'D:\Local\Elsewhere') $assistiveCatalog
        & $check ($uncAssistive.PSObject.Properties['TransferChannel'] -and $uncAssistive.TransferChannel -cne 'NonC' -and $uncAssistive.TransferChannel -ceq 'External') ('A UNC source draft must not default to NonC; an external share reuse is External: ['+[string]$uncAssistive.TransferChannel+']')
        $uncResolvedAssistive=Get-WsmMigrationSpecDraft (& $candidate '%FILESERVER%\data' '\\fs2\data\app' 'Machine' 'E:\Elsewhere') $assistiveCatalog
        & $check ($uncResolvedAssistive.TransferChannel -cne 'NonC' -and $uncResolvedAssistive.TransferChannel -ceq 'External') 'A resolved UNC candidate draft must not default to NonC either.'
        $nonCAssistive=Get-WsmMigrationSpecDraft (& $candidate 'D:\Data\app' 'D:\Data\app' 'Literal' '') $assistiveCatalog
        & $check ($nonCAssistive.TransferChannel -ceq 'NonC') 'A local non-C source keeps NonC.'
        $cAssistive=Get-WsmMigrationSpecDraft (& $candidate 'C:\Data\app' 'C:\Data\app' 'Literal' '') $assistiveCatalog
        & $check ($cAssistive.TransferChannel -ceq 'C') 'A local C source keeps C.'
        $plainChannel=Get-WsmMigrationSpecDraft (& $candidate '\\fs1\data\app' '\\fs1\data\app' 'Literal' '') $catalog
        & $check (-not $plainChannel.PSObject.Properties['TransferChannel']) 'A non-Assistive catalog draft still has no TransferChannel.'
        # 判定函式：另行遷移或其他無法自動決定的結果，不預設任何通道（欄位不存在＝必填），而不是退回 NonC。
        & $check ((Get-WsmDraftTransferChannel '\\fs1\data\app' $null) -ceq 'External') 'ExternalShareReuse maps to the External channel.'
        & $check ((Get-WsmDraftTransferChannel $srcInside $goodSpec) -ceq '') 'A SeparateMigration result must leave the channel empty (required), never NonC.'
        & $check ((Get-WsmDraftTransferChannel 'D:\x' $null) -ceq 'NonC' -and (Get-WsmDraftTransferChannel 'c:\x' $null) -ceq 'C') 'Local sources keep the C/NonC split.'
        Write-Host 'PASS: Q2c UNC draft channel.'
    } $root
}
finally {
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}
Write-Host 'PASS: UNC responsibility (classification, no local rewrite, three projections).'
