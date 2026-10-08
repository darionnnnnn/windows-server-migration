function Get-WsmMigrationSpecDraft($i,$c,[hashtable]$ServiceIndex=@{}) {
    $s=$i.Settings;$adapter='ManualWorkflow';$desired=$null;$final='Disabled'
    switch($i.Kind){
        Service {$adapter='Service';$desired=[pscustomobject]@{Name=$s.Name;DisplayName=$s.DisplayName;BinaryPathName=$s.PathName;Account=$(if($i.PSObject.Properties['AccountMapping'] -and $i.AccountMapping){$i.AccountMapping}else{$s.StartName});Dependencies=@($(if($ServiceIndex.ContainsKey($i.NaturalKey)){$ServiceIndex[$i.NaturalKey]}else{$c.Items | Where-Object {$_.Kind -eq 'ServiceRegistryDetails' -and $_.NaturalKey -ceq $i.NaturalKey} | ForEach-Object {if($_.Settings.PSObject.Properties['DependOnService']){$_.Settings.DependOnService};if($_.Settings.PSObject.Properties['DependOnGroup']){foreach($group in @($_.Settings.DependOnGroup)){if($group){'+'+[string]$group}}}}}));Description=$(if($s.PSObject.Properties['Description']){$s.Description}else{''})};if($s.PSObject.Properties['Supplement']){$desired | Add-Member NoteProperty Supplement $s.Supplement}else{$desired | Add-Member NoteProperty Supplement ([pscustomobject]@{ReviewRequired='Complete SCM supplement capture required; do not infer missing source fields.'})};if($s.StartMode -eq 'Auto'){$final='Automatic'}elseif($s.StartMode -eq 'Manual'){$final='Manual'}}
        ScheduledTask {$adapter='ScheduledTask';$xml=Read-WsmXml $s.Xml;$principal=$xml.SelectSingleNode("//*[local-name()='Principal']/*[local-name()='UserId']");$user='';if($principal){$user=$principal.InnerText};if($i.AccountMapping){$user=$i.AccountMapping};$desired=[pscustomobject]@{TaskName=$s.TaskName;TaskPath=$s.TaskPath;Xml=$s.Xml;User=$user};$enabled=$xml.SelectSingleNode("//*[local-name()='Settings']/*[local-name()='Enabled']");if($enabled -and $enabled.InnerText -eq 'true'){$final='Enabled'}}
        Share {$adapter='SmbShare';$path=$s.Definition.Path;if($i.Mapping){$path=$i.Mapping};$desired=[pscustomobject]@{Name=$s.Definition.Name;ScopeName=$(if($s.Definition.PSObject.Properties['ScopeName']){[string]$s.Definition.ScopeName}else{'*'});Path=$path;Description=$s.Definition.Description;EncryptData=[bool]$s.Definition.EncryptData;DrainPolicy='ReviewRequired';DrainEvidence='';Access=@($s.Access | Select-Object AccountName,AccessControlType,AccessRight)};$final='Enabled'}
        WindowsFeature {$adapter='WindowsFeature';$desired=[pscustomobject]@{Name=$s.Name;Source='';IsolationEvidence='';SideEffects=@()}}
        IISPool {$adapter='IISPool';$desired=[pscustomobject]@{Name=$i.NaturalKey;Xml=$s.Xml};$final='Enabled'}
        IISSite {$adapter='IISSite';$xml=Read-WsmXml $s.Xml;$bindings=@(foreach($binding in $xml.SelectNodes('//binding')){[pscustomobject]@{Protocol=$binding.GetAttribute('protocol');BindingInformation=$binding.GetAttribute('bindingInformation');CertificateHash='';CertificateStoreName='My';SslFlags=0}});$desired=[pscustomobject]@{Name=$i.NaturalKey;Xml=$s.Xml;Bindings=$bindings};$final='Enabled'}
        PathCandidate {$adapter='FileScope'}
        LocalUser {$adapter='LocalUser';$desired=[pscustomobject]@{Name=$s.Name;FullName='';Description=''};if(-not $s.Disabled){$final='Enabled'}}
        LocalGroup {$adapter='LocalGroup';$desired=[pscustomobject]@{Name=$s.Name;Description='';Members=@($s.Members | ForEach-Object {$_.Domain+'\'+$_.Name})}}
        Certificate {$adapter='Certificate';$store='Cert:\LocalMachine\My';if([string]$s.Store -match 'LocalMachine\\([^\\]+)$'){$store='Cert:\LocalMachine\'+$matches[1]};$desired=[pscustomobject]@{Thumbprint=$s.Thumbprint;Store=$store;ArtifactPath='';ArtifactHash='';HasPrivateKey=[bool]$s.HasPrivateKey}}
    }
    $spec=[pscustomobject][ordered]@{Adapter=$adapter;Owner='';Evidence='';DesiredFinalState=$final;BusinessChecks=@('Document configuration, permission, identity, endpoint and real application acceptance steps')}
    if($adapter -ceq 'ScheduledTask'){$security=Get-WsmTaskSecurityDraftFields $s;if($security.Count){foreach($field in @('SecuritySddl','FolderSecurity')){$desired | Add-Member NoteProperty $field $security[$field] -Force}}}
    if($adapter -eq 'ScheduledTask'){$spec | Add-Member NoteProperty CatchUpPolicy 'ReviewRequired';$spec.BusinessChecks+=@('Review missed executions and duplicate business transactions; record catch-up procedure and acceptance evidence')}
    if($adapter -eq 'FileScope'){$sourcePath=$s.OriginalPath;if($s.ResolvedCandidate){$sourcePath=$s.ResolvedCandidate};$targetPath=$sourcePath;if($i.Mapping){$targetPath=$i.Mapping};foreach($kv in @{SourcePath=$sourcePath;TargetPath=$targetPath;ExcludedRelativePaths=@();Consistency='OwnerFreeze';Metadata='DaclOwner';ConflictPolicy='Block';ConfigFiles=@();ConfigOverrides=@()}.GetEnumerator()){$spec | Add-Member NoteProperty $kv.Key $kv.Value}}
    elseif($adapter -eq 'ManualWorkflow'){$spec | Add-Member NoteProperty Product ($i.Category+'/'+$i.Kind);$spec | Add-Member NoteProperty Procedure ''; $spec | Add-Member NoteProperty Artifacts @()}
    else{$spec | Add-Member NoteProperty Desired $desired;if($adapter -eq 'LocalUser' -or ($adapter -eq 'Certificate' -and $desired.HasPrivateKey) -or ($adapter -eq 'Service' -and $desired.Account -notin @('LocalSystem','NT AUTHORITY\SYSTEM'))){$spec | Add-Member NoteProperty SecretRef ''}}
    if($adapter -ceq 'Service'){$account=[string]$desired.Account;if($account -match '^(?i:LocalSystem|SYSTEM|NT AUTHORITY\\SYSTEM|LocalService|NT AUTHORITY\\LocalService|NetworkService|NT AUTHORITY\\NetworkService|S-1-5-(?:18|19|20))$'){if($spec.PSObject.Properties['SecretRef']){$spec.PSObject.Properties.Remove('SecretRef')}}elseif($account.EndsWith('$')){$spec | Add-Member NoteProperty AccountMode 'ReviewRequired';$spec | Add-Member NoteProperty ManagedAccountEvidence ''}else{$spec | Add-Member NoteProperty AccountMode 'UserPassword'};if($s.PSObject.Properties['SecuritySddl']){$desired | Add-Member NoteProperty SecuritySddl $s.SecuritySddl}}
    $spec
}
function New-WsmMigrationSpecTemplate {
    param([string]$Workspace,[string]$PairId,[string]$ItemId,[string]$Path)
    $c=Get-WsmCatalog $Workspace $PairId;$rows=@($c.Items | Where-Object ItemId -CEQ $ItemId);if($rows.Count -ne 1){throw 'Unknown item.'};$spec=Get-WsmMigrationSpecDraft $rows[0] $c
    Write-WsmJson $Path $spec;[pscustomobject]@{Path=[IO.Path]::GetFullPath($Path);SHA256=(Get-FileHash -LiteralPath $Path).Hash;ItemId=$ItemId;Adapter=$spec.Adapter;DraftOnly=$true;RequiredReview='Owner/evidence, mappings, complete settings, credentials, final state, scope/exclusions and business checks must be reviewed.'}
}
function Read-WsmWizardValue([string]$Label,[switch]$Optional) {
    $value=Read-Host ($Label+'（0 取消；literal:0 表示文字 0）');if($null -eq $value){throw (New-Object IO.EndOfStreamException('Console input ended.'))};if($value -eq '0'){throw (New-Object OperationCanceledException('使用者取消，尚未提交本步驟。'))};if($value -ceq 'literal:0'){$value='0'};if(-not $Optional -and [string]::IsNullOrWhiteSpace($value)){throw 'Required value is blank.'};$value
}
function Select-WsmWizardPair([string]$Workspace) {
    $pairs=@((Get-WsmFleet $Workspace).Pairs);if(-not $pairs.Count){throw 'No host pairs registered.'};for($n=0;$n -lt $pairs.Count;$n++){Write-Host ('{0}. {1} -> {2} / Pair {3}' -f ($n+1),$pairs[$n].SourceName,$pairs[$n].TargetName,$pairs[$n].PairId)};$index=0;if(-not [int]::TryParse((Read-WsmWizardValue '配對編號'),[ref]$index) -or $index -lt 1 -or $index -gt $pairs.Count){throw 'Invalid pair choice.'};$pairs[$index-1].PairId
}
function Read-WsmWizardPackage {
    $path=Read-WsmWizardValue 'manifest.json 路徑';$hash=Read-WsmWizardValue '獨立可信 manifest SHA256';$p=Test-WsmMigrationPackage $path $hash;Write-Host ('Pair '+$p.Manifest.PairId+' / '+$p.Plan.Source.Name+' -> '+$p.Plan.Target.Name+' / generation '+$p.Manifest.Generation+' / IsolatedPilot');[pscustomobject]@{Path=$path;Hash=$hash;Package=$p}
}
function Read-WsmWizardRestorePackage([string]$StateDirectory,[ValidateSet('Source','Target')][string]$Role='Target') {
    $path=Read-WsmWizardValue 'manifest.json 路徑';$hash=Read-WsmWizardValue '獨立可信 manifest SHA256'
    # Authenticate the manifest and approved plan before creating the cancellation control directory.
    $manifest=Read-WsmTrustedJson $path $hash;Assert-WsmEnvelope $manifest 'MigrationPackage'
    Assert-WsmPackageHeaderContract $manifest
    if($manifest.Generation -lt 1 -or $manifest.Mode -cne 'IsolatedPilot' -or $manifest.PlanHash -cnotmatch '^[a-f0-9]{64}$' -or $manifest.ArtifactsHash -cnotmatch '^[a-f0-9]{64}$'){throw 'Invalid package identity, generation, mode or content binding.'}
    $planPath=Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path))) 'plan.json'
    $plan=Read-WsmMigrationPlan $planPath $manifest.PlanHash
    if($plan.PairId -cne $manifest.PairId -or $plan.BatchId -cne $manifest.BatchId -or $plan.ApprovalId -cne $manifest.ApprovalId -or $plan.Source.HostId -cne $manifest.Source.HostId -or $plan.Target.HostId -cne $manifest.Target.HostId -or $plan.Source.Fingerprint -cne $manifest.Source.Fingerprint -or $plan.Target.Fingerprint -cne $manifest.Target.Fingerprint -or $plan.DecisionRevision -ne $manifest.DecisionRevision -or $plan.InventoryRevision -ne $manifest.InventoryRevision){throw 'Package plan binding mismatch.'}
    Assert-WsmWorkspaceSeparation $plan $StateDirectory TargetPath;Assert-WsmSourceWorkspaceSeparation $plan $StateDirectory
    $expectedFingerprint=$manifest.Target.Fingerprint;if($Role -ceq 'Source'){$expectedFingerprint=$manifest.Source.Fingerprint};Assert-WsmMigrationHost (Get-WsmMachineIdentity) $expectedFingerprint
    $token=New-WsmWizardCancellation $manifest.PairId $manifest.PlanHash $hash $StateDirectory
    $package=Test-WsmMigrationPackage $path $hash $token
    Write-Host ('Pair '+$package.Manifest.PairId+' / '+$package.Plan.Source.Name+' -> '+$package.Plan.Target.Name+' / generation '+$package.Manifest.Generation+' / IsolatedPilot')
    [pscustomobject]@{Path=$path;Hash=$hash;Package=$package;CancellationToken=$token}
}
function Read-WsmWizardSecrets($Package) {
    $refs=@($Package.Plan.Items | Where-Object {$_.Decision -eq 'Include' -and $_.MigrationSpec.PSObject.Properties['SecretRef'] -and $_.MigrationSpec.SecretRef} | ForEach-Object {$_.MigrationSpec.SecretRef} | Select-Object -Unique);$secrets=@{};foreach($ref in $refs){$credential=Get-Credential -Message ('Required SecretRef '+$ref+'; only stored in memory');if(-not $credential){throw (New-Object OperationCanceledException('Credential entry cancelled.'))};$secrets[$ref]=$credential};return ,$secrets
}
function New-WsmWizardCancellation($PairId,$PlanHash,$ManifestHash,$StateDirectory) {
    $root=[IO.Path]::GetFullPath($StateDirectory);Assert-WsmNoReparse $root
    if(-not [IO.Directory]::Exists($root)){[void][IO.Directory]::CreateDirectory($root);Protect-WsmDirectory $root}
    $token=New-WsmCancellationToken $PairId $PlanHash $ManifestHash ([Guid]::NewGuid().ToString()) $root
    $pairRoot=Join-Path $root $PairId;Assert-WsmNoReparse $pairRoot
    if(-not [IO.Directory]::Exists($pairRoot)){[void][IO.Directory]::CreateDirectory($pairRoot);Protect-WsmDirectory $pairRoot}else{Assert-WsmCancellationDirectoryProtection $pairRoot}
    $path=Join-Path $pairRoot ('cancel-token-'+$token.OperationId+'.json');Write-WsmJson $path $token
    Write-Host ('本次 OperationId：'+$token.OperationId)
    Write-Host ('取消控制檔：'+$path+' / SHA256：'+(Get-FileHash -LiteralPath $path).Hash)
    Write-Host '需要取消時，另開本機管理員 PowerShell 執行選單角色 5，輸入控制檔與可信 SHA256。系統在安全邊界停止並保留復原證據；勿直接關閉程序。'
    $token
}
function Show-WsmMigrationWizard {
    param([string]$Workspace)
    while($true){Write-Host "`n遷移角色：1 管理工作區  2 來源本機  3 目標本機  4 進階操作請求  5 請求取消執行中的作業  6 測試主機驗證報告（複製貼回）  0 返回";$role=Read-Host '角色';if($null -eq $role){throw (New-Object IO.EndOfStreamException('Console input ended.'))};if($role -eq '0'){return};try{switch($role){
        '1' {Write-Host '1 產生逐項規格草稿  2 設定已檢查規格  3 核准隔離 pilot 遷移計畫  4 SID／帳號對應  5 工作區交易修復  6 批次規格草稿  7 批次規格預覽／提交  8 跨主機群組／資格矩陣操作  0 返回';$step=Read-Host '操作';if($null -eq $step){throw (New-Object IO.EndOfStreamException('Console input ended.'))};if($step -eq '0'){continue};if($step -eq '8'){Show-WsmMigrationMenu $Workspace;continue};if($step -eq '5'){Repair-WsmWorkspace $Workspace | Format-List;continue};$pair=Select-WsmWizardPair $Workspace;$c=Get-WsmCatalog $Workspace $pair;switch($step){
            '1' {$search=Read-WsmWizardValue '搜尋項目名稱' -Optional;Get-WsmItems $Workspace $pair -Search $search -PageSize 100 | Select-Object -ExpandProperty Items | Select-Object Name,Kind,ItemId | Format-Table;New-WsmMigrationSpecTemplate $Workspace $pair (Read-WsmWizardValue '完整 ItemId') (Read-WsmWizardValue '規格草稿 JSON 輸出路徑') | Format-List}
            '6' {Export-WsmMigrationSpecBundle $Workspace $pair (Read-WsmWizardValue '批次規格 JSON 輸出路徑') -Category (Read-WsmWizardValue '類別（全部留空）' -Optional) -Search (Read-WsmWizardValue 'literal 搜尋（全部留空）' -Optional) | Format-List}
            '7' {$bundle=Read-WsmWizardValue '已填完且審核過的批次規格 JSON';$bundleHash=Read-WsmWizardValue '可信 bundle SHA256';$preview=Get-WsmMigrationSpecBundlePreview $Workspace $pair $bundle $bundleHash;$preview | Select-Object Selected,Invalid,Blocked,DecisionRevision | Format-List;$preview.Sample | Format-Table;$preview.Errors | Format-Table;if(-not $preview.Blocked){Import-WsmMigrationSpecBundle $Workspace $pair $bundle $bundleHash $preview.DecisionRevision (Read-WsmWizardValue '確認預覽的整批規格，輸入 APPLY-SPECS') | Format-List}}
            '4' {Set-WsmIdentityMap $Workspace $pair (Read-WsmWizardValue '已審核 IdentityMap JSON') (Read-WsmWizardValue '可信 SHA256') $c.DecisionRevision}
            '2' {Set-WsmMigrationSpec $Workspace $pair (Read-WsmWizardValue '完整 ItemId') (Read-WsmWizardValue '已填完且檢查過的規格 JSON') (Read-WsmWizardValue '可信規格 SHA256') $c.DecisionRevision}
            '3' {Approve-WsmMigrationPlan $Workspace $pair (Read-WsmWizardValue '目標身分 JSON') (Read-WsmWizardValue '目標身分可信 SHA256') (Read-WsmWizardValue '核准遷移計畫輸出路徑') $c.DecisionRevision (Read-WsmWizardValue '尚未實機資格驗收，輸入 ISOLATED-PILOT 確认隔離測試') | Format-List}
            default{Write-Host 'Invalid choice.'}
        }}
        '2' {Write-Host '1 空間／scope 預檢  2 匯出搬移包／重試  3 停寫及身分釋放記錄  4 分卷 ZIP  5 匯出來源結果  6 raw 證據索引  7 明確回復來源  8 排程中斷協調證據草稿  9 initial／final 差異 ZIP  10 來源設定檔審核草稿  11 核准設定檔即時差異報告  0 返回';$step=Read-Host '操作';if($null -eq $step){throw (New-Object IO.EndOfStreamException('Console input ended.'))};if($step -eq '0'){continue};if($step -eq '9'){Show-WsmDeltaWizard -Role Source;continue};if($step -eq '11'){Export-WsmConfigArtifactReview -PlanPath (Read-WsmWizardValue 'MigrationPlan JSON') -ExpectedHash (Read-WsmWizardValue '獨立可信計畫 SHA256') -Path (Read-WsmWizardValue '設定差異報告輸出路徑') | Format-List;continue};if($step -eq '10'){Export-WsmConfigArtifactScopeDraft -SpecPath (Read-WsmWizardValue '來源 FileScope 規格草稿 JSON') -ExpectedHash (Read-WsmWizardValue '可信規格 SHA256') -ItemId (Read-WsmWizardValue '來源完整 ItemId') -Path (Read-WsmWizardValue '設定檔審核草稿輸出路徑') | Format-List;continue};if($step -eq '6'){Export-WsmRawEvidenceManifest (Read-WsmWizardValue 'Inventory JSON') (Read-WsmWizardValue '可信 SHA256') (Read-WsmWizardValue 'raw 索引輸出路徑') | Format-List;continue};if($step -eq '5'){$p=Read-WsmWizardPackage;Export-WsmSourceStageResult $p.Path $p.Hash (Read-WsmWizardValue '來源受控狀態目錄') (Read-WsmWizardValue 'Export／FinalDelta') (Read-WsmWizardValue 'StageResult 輸出路徑') | Format-List;continue};if($step -eq '4'){$output=Read-WsmWizardValue 'ZIP 輸出目錄';$p=Read-WsmWizardRestorePackage $output Source;Export-WsmPackageZip $p.Path $p.Hash $output -CancellationToken $p.CancellationToken | Format-List;continue};$plan=Read-WsmWizardValue 'MigrationPlan JSON';$hash=Read-WsmWizardValue '獨立可信計畫 SHA256';switch($step){
            '1' {Get-WsmPackageEstimate $plan $hash (Read-WsmWizardValue '包輸出目錄') | Format-List}
            '2' {$source=Read-WsmWizardValue '本機原盤點目錄';$output=Read-WsmWizardValue '包輸出目錄';$base=Read-WsmWizardValue 'final delta 的基底 manifest（初始包留空）' -Optional;$baseHash='';$freeze='';$freezeHash='';if($base){$baseHash=Read-WsmWizardValue '基底可信 SHA256'};$freeze=Read-WsmWizardValue '停寫記錄（mutable／final 必填）' -Optional;if($freeze){$freezeHash=Read-WsmWizardValue '停寫記錄可信 SHA256'};$approved=Read-WsmMigrationPlan $plan $hash;$token=New-WsmWizardCancellation $approved.PairId $hash '' $source;Export-WsmMigrationPackage $plan $hash $source $output -BaseManifestPath $base -BaseManifestHash $baseHash -FreezePath $freeze -FreezeHash $freezeHash -CancellationToken $token | Format-List}
            '7' {$source=Read-WsmWizardValue '來源受控狀態目錄';$attempt=Read-WsmWizardValue 'SourceAttempt JSON';$attemptHash=Read-WsmWizardValue 'SourceAttempt 可信 SHA256';$owner=Read-WsmWizardValue '責任人';$proof=Read-WsmWizardValue '目標停寫／資料協調／來源取得唯一寫入權的證據';$taskProof=Read-WsmWizardValue 'SourceTaskReconciliation JSON（原本執行中排程必填；無則留空）' -Optional;$taskProofHash='';if($taskProof){$taskProofHash=Read-WsmWizardValue '排程工作協調證據可信 SHA256'};$approved=Read-WsmMigrationPlan $plan $hash;$ack='SOURCE-OWNERSHIP-RESTORED '+$approved.PairId;Invoke-WsmSourceResume $plan $hash $attempt $attemptHash $source $owner $proof $ack -TaskReconciliationPath $taskProof -TaskReconciliationHash $taskProofHash -WhatIf | Format-List;Invoke-WsmSourceResume $plan $hash $attempt $attemptHash $source $owner $proof (Read-WsmWizardValue ('核對原始啟用狀態後輸入 '+$ack)) -TaskReconciliationPath $taskProof -TaskReconciliationHash $taskProofHash | Format-List}
            '8' {Export-WsmSourceTaskReconciliationTemplate -PlanPath $plan -ExpectedHash $hash -SourceAttemptPath (Read-WsmWizardValue '目前 SourceAttempt JSON') -SourceAttemptHash (Read-WsmWizardValue '目前 attempt 可信 SHA256') -Path (Read-WsmWizardValue '協調證據草稿輸出 JSON') | Format-List}
            '3' {$released=(Read-WsmWizardValue '舊 hostname／IP 已釋放？ YES／NO') -ceq 'YES';$previous=Read-WsmWizardValue '前次 SourceAttempt（中斷重試留原始基準；首次留空）' -Optional;$previousHash='';if($previous){$previousHash=Read-WsmWizardValue '前次 attempt 可信 SHA256'};$release='';if($released){$release=Read-WsmWizardValue '身分／IP／網域釋放的獨立證據'};Export-WsmFreezeRecord $plan $hash (Read-WsmWizardValue '停寫記錄輸出路徑') (Read-WsmWizardValue '服務責任人') (Read-WsmWizardValue '停寫與外部 writer 驗證證據') (Read-WsmWizardValue '輸入 OWNER-CONFIRMED-QUIESCENCE') -SourceStateDirectory (Read-WsmWizardValue '原盤點目錄') -SourceIdentityReleased:$released -ReleaseEvidence $release -PreviousAttemptPath $previous -PreviousAttemptHash $previousHash | Format-List}
            default{Write-Host 'Invalid choice.'}
        }}
        '3' {Write-Host '1 登記目標固定身分  2 匯入分卷 ZIP  3 還原預覽  4 還原／重試  5 驗收證據  6 設定／業務驗證  7 產生切換預覽  8 明確執行切換  9 完成／退役門檻  10 回復預覽／執行  11 修復 checkpoint  12 匯出結果  13 遷移報告  14 中斷啟用的審核接續  15 增量匯入／套用／修復  0 返回';$step=Read-Host '操作';if($null -eq $step){throw (New-Object IO.EndOfStreamException('Console input ended.'))};if($step -eq '0'){continue};if($step -eq '15'){Show-WsmDeltaWizard -Role Target;continue};$state=Read-WsmWizardValue '本機受控狀態目錄';if($step -eq '1'){Register-WsmTarget $state (Read-WsmWizardValue '目標身分 JSON 輸出路徑') | Format-List;continue};if($step -eq '2'){$transport=Read-WsmWizardValue 'transport.json';$transportHash=Read-WsmWizardValue '獨立可信 transport SHA256';$output=Read-WsmWizardValue '搬移包匯入目錄';$t=Read-WsmTrustedJson $transport $transportHash;Assert-WsmEnvelope $t 'PackageTransport';$token=New-WsmWizardCancellation $t.PairId $t.PlanHash $t.ManifestHash $output;Import-WsmPackageZip $transport $transportHash $output -CancellationToken $token | Format-List;continue};$p=$null;if($step -in @('3','4')){$p=Read-WsmWizardRestorePackage $state}else{$p=Read-WsmWizardPackage};$secrets=@{};try{switch($step){
            '3' {$secrets=Read-WsmWizardSecrets $p.Package;Get-WsmRestorePreview $p.Path $p.Hash $state $secrets $p.CancellationToken | Format-List}
            '4' {$secrets=Read-WsmWizardSecrets $p.Package;$preview=Get-WsmRestorePreview $p.Path $p.Hash $state $secrets $p.CancellationToken;$preview.Rows | Format-Table;$preview.Problems | Format-Table;if((Read-WsmWizardValue ('確認 Pair '+$p.Package.Manifest.PairId+'，輸入 RESTORE')) -ceq 'RESTORE'){Invoke-WsmRestore $p.Path $p.Hash $state $secrets -CancellationToken $p.CancellationToken | Format-List}}
            '5' {Set-WsmValidationEvidence $p.Path $p.Hash $state (Read-WsmWizardValue 'ItemId（全機門檻留空）' -Optional) (Read-WsmWizardValue 'Check：BusinessStaged／BusinessFinal／ManualRestore／DNS／Kerberos／ExternalConnectivity／Monitoring／BackupRestore／LongCycleJobs／SecurityAgent／License／UserAcceptance／Observation／RollbackReconcile／RetirementRetention') (Read-WsmWizardValue '負責人') (Read-WsmWizardValue '驗收方法／預期／實際／證據參考') ((Read-WsmWizardValue '實際通過？ YES／NO') -ceq 'YES') | Format-List}
            '6' {Invoke-WsmValidation $p.Path $p.Hash $state (Read-WsmWizardValue 'Staged／Final') | Format-List}
            '7' {$dependency=Read-WsmWizardValue '跨主機 provider 證據索引（無必要相依留空）' -Optional;$groupIndex=Read-WsmWizardValue '跨主機一致性群組索引（無群組留空）' -Optional;$groupHash='';if($groupIndex){$groupHash=Read-WsmWizardValue '群組索引可信 SHA256'};$dependencyHash='';if($dependency){$dependencyHash=Read-WsmWizardValue 'provider 索引可信 SHA256'};New-WsmCutoverPlan $p.Path $p.Hash $state (Read-WsmWizardValue '已審核 network JSON') (Read-WsmWizardValue 'network 可信 SHA256') (Read-WsmWizardValue '切換預覽輸出路徑') -DependencyEvidencePath $dependency -DependencyEvidenceHash $dependencyHash -GroupEvidenceIndexPath $groupIndex -GroupEvidenceIndexHash $groupHash | Format-List}
            '8' {if((Read-WsmWizardValue '改名需要網域認證？ YES／NO') -ceq 'YES'){$credential=Get-Credential -Message 'DomainRename：核准的網域改名認證，只保留在記憶體';if(-not $credential){throw (New-Object OperationCanceledException('Credential entry cancelled.'))};$secrets.DomainRename=$credential};Invoke-WsmCutover $p.Path $p.Hash $state (Read-WsmWizardValue 'CutoverPlan JSON') (Read-WsmWizardValue '可信切換計畫 SHA256') (Read-WsmWizardValue ('輸入 CUTOVER '+$p.Package.Manifest.PairId)) -Secrets $secrets | Format-List}
            '9' {Get-WsmAcceptanceGates $p.Path $p.Hash $state | Format-List}
            '10' {$preview=Get-WsmRollbackPreview $p.Path $p.Hash $state;$preview | Format-List;$preview.Rows | Format-Table;Invoke-WsmRollback $p.Path $p.Hash $state $preview.PreviewHash (Read-WsmWizardValue ('確認具體回復項目，輸入 ROLLBACK '+$p.Package.Manifest.PairId)) | Format-List}
            '11' {Repair-WsmOperation $p.Path $p.Hash $state | Format-List}
            '12' {Export-WsmStageResult $p.Path $p.Hash $state (Read-WsmWizardValue 'Restore／PreCutoverValidation／Cutover／PostCutoverValidation／Retirement') (Read-WsmWizardValue 'StageResult 輸出路徑') | Format-List}
            '14' {Invoke-WsmCutover $p.Path $p.Hash $state (Read-WsmWizardValue '原核准 CutoverPlan JSON') (Read-WsmWizardValue '可信切換計畫 SHA256') (Read-WsmWizardValue ('輸入 CUTOVER '+$p.Package.Manifest.PairId)) -ResumeActivation -ResumeOwner (Read-WsmWizardValue '啟用接續責任人') -ResumeEvidence (Read-WsmWizardValue '已協調可能新增交易、確認來源仍停寫與啟用接續的證據') | Format-List}
            '13' {Export-WsmOperationReport $p.Path $p.Hash $state (Read-WsmWizardValue 'HTML 輸出路徑') | Format-List}
            default{Write-Host 'Invalid choice.'}
        }}finally{$secrets.Clear()}}
        '4' {Show-WsmMigrationMenu $Workspace}
        '6' {Show-WsmLabReportWizard}
        '5' {$token=Read-WsmTrustedJson (Read-WsmWizardValue '取消控制檔 JSON') (Read-WsmWizardValue '獨立可信控制檔 SHA256');Request-WsmCancellation $token (Read-WsmWizardValue '取消責任人') (Read-WsmWizardValue '取消理由／證據') | Format-List}
        default{Write-Host 'Invalid role.'}
    }}catch [OperationCanceledException]{Write-Host $_.Exception.Message}catch [IO.EndOfStreamException]{throw}catch{Write-Host ('操作失敗：'+$_.Exception.Message) -ForegroundColor Red;Get-WsmFailureDetails $_ | Format-List Category,NativeCode,Hint}}
}

function Show-WsmLabReportWizard {
    $role=Read-WsmWizardValue '本機角色 Source／Target'
    if($role -cnotin @('Source','Target')){throw (New-WsmContractError 'Invalid lab report role.')}
    $mode=Read-WsmWizardValue '1 環境／盤點檢查（未還原也可用）／2 已核准搬移包逐項驗證'
    $arguments=@{Role=$role;OutputDirectory=(Read-WsmWizardValue '驗證報告輸出目錄（不可放入搬移 scope）')}
    if($mode -ceq '2'){
        $arguments.ManifestPath=Read-WsmWizardValue 'MigrationPackage manifest.json 路徑'
        $arguments.ExpectedHash=Read-WsmWizardValue '獨立可信 manifest SHA256'
        $arguments.Phase=Read-WsmWizardValue '驗證階段 Staged／Final'
        if($arguments.Phase -cnotin @('Staged','Final')){throw (New-WsmContractError 'Invalid lab report phase.')}
        if($role -ceq 'Target'){$arguments.StateDirectory=Read-WsmWizardValue '本機還原的受控狀態目錄'}
    }elseif($mode -cne '1'){throw (New-WsmContractError 'Invalid lab report mode.')}
    Export-WsmLabValidationReport @arguments | Format-List
    Write-Host '開啟回傳的文字報告，將完整區塊複製貼回；保留 JSON 與 SHA256。NotTested／Blocked 不代表驗證通過。'
}