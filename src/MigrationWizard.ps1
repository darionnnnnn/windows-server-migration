function Get-WsmMigrationSpecDraft($i,$c,[hashtable]$ServiceIndex=@{}) {
    $s=$i.Settings;$adapter='ManualWorkflow';$desired=$null;$final='Disabled'
    switch($i.Kind){
        Service {$adapter='Service';$desired=[pscustomobject]@{Name=$s.Name;DisplayName=$s.DisplayName;BinaryPathName=$s.PathName;Account=$s.StartName;Dependencies=@($(if($ServiceIndex.ContainsKey($i.NaturalKey)){$ServiceIndex[$i.NaturalKey]}else{$c.Items | Where-Object {$_.Kind -eq 'ServiceRegistryDetails' -and $_.NaturalKey -ceq $i.NaturalKey} | ForEach-Object {if($_.Settings.PSObject.Properties['DependOnService']){$_.Settings.DependOnService}}}));Description=$(if($s.PSObject.Properties['Description']){$s.Description}else{''})};if($s.StartMode -eq 'Auto'){$final='Automatic'}elseif($s.StartMode -eq 'Manual'){$final='Manual'}}
        ScheduledTask {$adapter='ScheduledTask';$xml=Read-WsmXml $s.Xml;$principal=$xml.SelectSingleNode("//*[local-name()='Principal']/*[local-name()='UserId']");$user='';if($principal){$user=$principal.InnerText};if($i.AccountMapping){$user=$i.AccountMapping};$desired=[pscustomobject]@{TaskName=$s.TaskName;TaskPath=$s.TaskPath;Xml=$s.Xml;User=$user};$enabled=$xml.SelectSingleNode("//*[local-name()='Settings']/*[local-name()='Enabled']");if($enabled -and $enabled.InnerText -eq 'true'){$final='Enabled'}}
        Share {$adapter='SmbShare';$path=$s.Definition.Path;if($i.Mapping){$path=$i.Mapping};$desired=[pscustomobject]@{Name=$s.Definition.Name;Path=$path;Description=$s.Definition.Description;EncryptData=[bool]$s.Definition.EncryptData;Access=@($s.Access | Select-Object AccountName,AccessControlType,AccessRight)};$final='Enabled'}
        WindowsFeature {$adapter='WindowsFeature';$desired=[pscustomobject]@{Name=$s.Name;Source=''}}
        IISPool {$adapter='IISPool';$desired=[pscustomobject]@{Name=$i.NaturalKey;Xml=$s.Xml};$final='Enabled'}
        IISSite {$adapter='IISSite';$xml=Read-WsmXml $s.Xml;$bindings=@(foreach($binding in $xml.SelectNodes('//binding')){[pscustomobject]@{Protocol=$binding.GetAttribute('protocol');BindingInformation=$binding.GetAttribute('bindingInformation');CertificateHash='';CertificateStoreName='My';SslFlags=0}});$desired=[pscustomobject]@{Name=$i.NaturalKey;Xml=$s.Xml;Bindings=$bindings};$final='Enabled'}
        PathCandidate {$adapter='FileScope'}
        LocalUser {$adapter='LocalUser';$desired=[pscustomobject]@{Name=$s.Name;FullName='';Description=''};if(-not $s.Disabled){$final='Enabled'}}
        LocalGroup {$adapter='LocalGroup';$desired=[pscustomobject]@{Name=$s.Name;Description='';Members=@($s.Members | ForEach-Object {$_.Domain+'\'+$_.Name})}}
        Certificate {$adapter='Certificate';$store='Cert:\LocalMachine\My';if([string]$s.Store -match 'LocalMachine\\([^\\]+)$'){$store='Cert:\LocalMachine\'+$matches[1]};$desired=[pscustomobject]@{Thumbprint=$s.Thumbprint;Store=$store;ArtifactPath='';ArtifactHash='';HasPrivateKey=[bool]$s.HasPrivateKey}}
    }
    $spec=[pscustomobject][ordered]@{Adapter=$adapter;Owner='';Evidence='';DesiredFinalState=$final;BusinessChecks=@('Document configuration, permission, identity, endpoint and real application acceptance steps')}
    if($adapter -eq 'FileScope'){$sourcePath=$s.OriginalPath;if($s.ResolvedCandidate){$sourcePath=$s.ResolvedCandidate};$targetPath=$sourcePath;if($i.Mapping){$targetPath=$i.Mapping};foreach($kv in @{SourcePath=$sourcePath;TargetPath=$targetPath;ExcludedRelativePaths=@();Consistency='OwnerFreeze';Metadata='DaclOwner';ConflictPolicy='Block'}.GetEnumerator()){$spec | Add-Member NoteProperty $kv.Key $kv.Value}}
    elseif($adapter -eq 'ManualWorkflow'){$spec | Add-Member NoteProperty Product ($i.Category+'/'+$i.Kind);$spec | Add-Member NoteProperty Procedure ''; $spec | Add-Member NoteProperty Artifacts @()}
    else{$spec | Add-Member NoteProperty Desired $desired;if($adapter -eq 'LocalUser' -or ($adapter -eq 'Certificate' -and $desired.HasPrivateKey) -or ($adapter -eq 'Service' -and $desired.Account -notin @('LocalSystem','NT AUTHORITY\SYSTEM'))){$spec | Add-Member NoteProperty SecretRef ''}}
    $spec
}
function New-WsmMigrationSpecTemplate {
    param([string]$Workspace,[string]$PairId,[string]$ItemId,[string]$Path)
    $c=Get-WsmCatalog $Workspace $PairId;$rows=@($c.Items | Where-Object ItemId -CEQ $ItemId);if($rows.Count -ne 1){throw 'Unknown item.'};$spec=Get-WsmMigrationSpecDraft $rows[0] $c
    Write-WsmJson $Path $spec;[pscustomobject]@{Path=[IO.Path]::GetFullPath($Path);SHA256=(Get-FileHash -LiteralPath $Path).Hash;ItemId=$ItemId;Adapter=$spec.Adapter;DraftOnly=$true;RequiredReview='Owner/evidence, mappings, complete settings, credentials, final state, scope/exclusions and business checks must be reviewed.'}
}
function Read-WsmWizardValue([string]$Label,[switch]$Optional) {
    $value=Read-Host ($Label+'（0 取消）');if($value -eq '0' -or $null -eq $value){throw (New-Object OperationCanceledException('使用者取消，尚未提交本步驟。'))};if(-not $Optional -and [string]::IsNullOrWhiteSpace($value)){throw 'Required value is blank.'};$value
}
function Select-WsmWizardPair([string]$Workspace) {
    $pairs=@((Get-WsmFleet $Workspace).Pairs);if(-not $pairs.Count){throw 'No host pairs registered.'};for($n=0;$n -lt $pairs.Count;$n++){Write-Host ('{0}. {1} -> {2} / Pair {3}' -f ($n+1),$pairs[$n].SourceName,$pairs[$n].TargetName,$pairs[$n].PairId)};$index=0;if(-not [int]::TryParse((Read-WsmWizardValue '配對編號'),[ref]$index) -or $index -lt 1 -or $index -gt $pairs.Count){throw 'Invalid pair choice.'};$pairs[$index-1].PairId
}
function Read-WsmWizardPackage {
    $path=Read-WsmWizardValue 'manifest.json 路徑';$hash=Read-WsmWizardValue '獨立可信 manifest SHA256';$p=Test-WsmMigrationPackage $path $hash;Write-Host ('Pair '+$p.Manifest.PairId+' / '+$p.Plan.Source.Name+' -> '+$p.Plan.Target.Name+' / generation '+$p.Manifest.Generation+' / IsolatedPilot');[pscustomobject]@{Path=$path;Hash=$hash;Package=$p}
}
function Read-WsmWizardSecrets($Package) {
    $refs=@($Package.Plan.Items | Where-Object {$_.Decision -eq 'Include' -and $_.MigrationSpec.PSObject.Properties['SecretRef'] -and $_.MigrationSpec.SecretRef} | ForEach-Object {$_.MigrationSpec.SecretRef} | Select-Object -Unique);$secrets=@{};foreach($ref in $refs){$credential=Get-Credential -Message ('Required SecretRef '+$ref+'; only stored in memory');if(-not $credential){throw (New-Object OperationCanceledException('Credential entry cancelled.'))};$secrets[$ref]=$credential};return ,$secrets
}
function Show-WsmMigrationWizard {
    param([string]$Workspace)
    while($true){Write-Host "`n遷移角色：1 管理工作區  2 來源本機  3 目標本機  4 進階操作請求  0 返回";$role=Read-Host '角色';if($role -eq '0'){return};try{switch($role){
        '1' {Write-Host '1 產生逐項規格草稿  2 設定已檢查規格  3 核准隔離 pilot 遷移計畫  4 SID／帳號對應  5 工作區交易修復  6 批次規格草稿  7 批次規格預覽／提交  0 返回';$step=Read-Host '操作';if($step -eq '0'){continue};if($step -eq '5'){Repair-WsmWorkspace $Workspace | Format-List;continue};$pair=Select-WsmWizardPair $Workspace;$c=Get-WsmCatalog $Workspace $pair;switch($step){
            '1' {$search=Read-WsmWizardValue '搜尋項目名稱' -Optional;Get-WsmItems $Workspace $pair -Search $search -PageSize 100 | Select-Object -ExpandProperty Items | Select-Object Name,Kind,ItemId | Format-Table;New-WsmMigrationSpecTemplate $Workspace $pair (Read-WsmWizardValue '完整 ItemId') (Read-WsmWizardValue '規格草稿 JSON 輸出路徑') | Format-List}
            '6' {Export-WsmMigrationSpecBundle $Workspace $pair (Read-WsmWizardValue '批次規格 JSON 輸出路徑') -Category (Read-WsmWizardValue '類別（全部留空）' -Optional) -Search (Read-WsmWizardValue 'literal 搜尋（全部留空）' -Optional) | Format-List}
            '7' {$bundle=Read-WsmWizardValue '已填完且審核過的批次規格 JSON';$bundleHash=Read-WsmWizardValue '可信 bundle SHA256';$preview=Get-WsmMigrationSpecBundlePreview $Workspace $pair $bundle $bundleHash;$preview | Select-Object Selected,Invalid,Blocked,DecisionRevision | Format-List;$preview.Sample | Format-Table;$preview.Errors | Format-Table;if(-not $preview.Blocked){Import-WsmMigrationSpecBundle $Workspace $pair $bundle $bundleHash $preview.DecisionRevision (Read-WsmWizardValue '確認預覽的整批規格，輸入 APPLY-SPECS') | Format-List}}
            '4' {Set-WsmIdentityMap $Workspace $pair (Read-WsmWizardValue '已審核 IdentityMap JSON') (Read-WsmWizardValue '可信 SHA256') $c.DecisionRevision}
            '2' {Set-WsmMigrationSpec $Workspace $pair (Read-WsmWizardValue '完整 ItemId') (Read-WsmWizardValue '已填完且檢查過的規格 JSON') (Read-WsmWizardValue '可信規格 SHA256') $c.DecisionRevision}
            '3' {Approve-WsmMigrationPlan $Workspace $pair (Read-WsmWizardValue '目標身分 JSON') (Read-WsmWizardValue '目標身分可信 SHA256') (Read-WsmWizardValue '核准遷移計畫輸出路徑') $c.DecisionRevision (Read-WsmWizardValue '尚未實機資格驗收，輸入 ISOLATED-PILOT 確认隔離測試') | Format-List}
            default{Write-Host 'Invalid choice.'}
        }}
        '2' {Write-Host '1 空間／scope 預檢  2 匯出搬移包／重試  3 停寫及身分釋放記錄  4 分卷 ZIP  5 匯出來源結果  6 raw 證據索引  0 返回';$step=Read-Host '操作';if($step -eq '0'){continue};if($step -eq '6'){Export-WsmRawEvidenceManifest (Read-WsmWizardValue 'Inventory JSON') (Read-WsmWizardValue '可信 SHA256') (Read-WsmWizardValue 'raw 索引輸出路徑') | Format-List;continue};if($step -eq '5'){$p=Read-WsmWizardPackage;Export-WsmSourceStageResult $p.Path $p.Hash (Read-WsmWizardValue '來源受控狀態目錄') (Read-WsmWizardValue 'Export／FinalDelta') (Read-WsmWizardValue 'StageResult 輸出路徑') | Format-List;continue};if($step -eq '4'){$p=Read-WsmWizardPackage;Export-WsmPackageZip $p.Path $p.Hash (Read-WsmWizardValue 'ZIP 輸出目錄') | Format-List;continue};$plan=Read-WsmWizardValue 'MigrationPlan JSON';$hash=Read-WsmWizardValue '獨立可信計畫 SHA256';switch($step){
            '1' {Get-WsmPackageEstimate $plan $hash (Read-WsmWizardValue '包輸出目錄') | Format-List}
            '2' {$source=Read-WsmWizardValue '本機原盤點目錄';$output=Read-WsmWizardValue '包輸出目錄';$base=Read-WsmWizardValue 'final delta 的基底 manifest（初始包留空）' -Optional;$baseHash='';$freeze='';$freezeHash='';if($base){$baseHash=Read-WsmWizardValue '基底可信 SHA256'};$freeze=Read-WsmWizardValue '停寫記錄（mutable／final 必填）' -Optional;if($freeze){$freezeHash=Read-WsmWizardValue '停寫記錄可信 SHA256'};Export-WsmMigrationPackage $plan $hash $source $output -BaseManifestPath $base -BaseManifestHash $baseHash -FreezePath $freeze -FreezeHash $freezeHash | Format-List}
            '3' {$released=(Read-WsmWizardValue '舊 hostname／IP 已釋放？ YES／NO') -ceq 'YES';$release='';if($released){$release=Read-WsmWizardValue '身分／IP／網域釋放的獨立證據'};Export-WsmFreezeRecord $plan $hash (Read-WsmWizardValue '停寫記錄輸出路徑') (Read-WsmWizardValue '服務責任人') (Read-WsmWizardValue '停寫與外部 writer 驗證證據') (Read-WsmWizardValue '輸入 OWNER-CONFIRMED-QUIESCENCE') -SourceStateDirectory (Read-WsmWizardValue '原盤點目錄') -SourceIdentityReleased:$released -ReleaseEvidence $release | Format-List}
            default{Write-Host 'Invalid choice.'}
        }}
        '3' {Write-Host '1 登記目標固定身分  2 匯入分卷 ZIP  3 還原預覽  4 還原／重試  5 驗收證據  6 設定／業務驗證  7 產生切換預覽  8 明確執行切換  9 完成／退役門檻  10 回復預覽／執行  11 修復 checkpoint  12 匯出結果  13 遷移報告  0 返回';$step=Read-Host '操作';if($step -eq '0'){continue};$state=Read-WsmWizardValue '本機受控狀態目錄';if($step -eq '1'){Register-WsmTarget $state (Read-WsmWizardValue '目標身分 JSON 輸出路徑') | Format-List;continue};if($step -eq '2'){Import-WsmPackageZip (Read-WsmWizardValue 'transport.json') (Read-WsmWizardValue '獨立可信 transport SHA256') (Read-WsmWizardValue '搬移包匯入目錄') | Format-List;continue};$p=Read-WsmWizardPackage;$secrets=@{};try{switch($step){
            '3' {$secrets=Read-WsmWizardSecrets $p.Package;Get-WsmRestorePreview $p.Path $p.Hash $state $secrets | Format-List}
            '4' {$secrets=Read-WsmWizardSecrets $p.Package;$preview=Get-WsmRestorePreview $p.Path $p.Hash $state $secrets;$preview.Rows | Format-Table;$preview.Problems | Format-Table;if((Read-WsmWizardValue ('確認 Pair '+$p.Package.Manifest.PairId+'，輸入 RESTORE')) -ceq 'RESTORE'){Invoke-WsmRestore $p.Path $p.Hash $state $secrets | Format-List}}
            '5' {Set-WsmValidationEvidence $p.Path $p.Hash $state (Read-WsmWizardValue 'ItemId（全機門檻留空）' -Optional) (Read-WsmWizardValue 'Check：BusinessStaged／BusinessFinal／ManualRestore／DNS／Kerberos／ExternalConnectivity／Monitoring／BackupRestore／LongCycleJobs／SecurityAgent／License／UserAcceptance／Observation／RollbackReconcile／RetirementRetention') (Read-WsmWizardValue '負責人') (Read-WsmWizardValue '驗收方法／預期／實際／證據參考') ((Read-WsmWizardValue '實際通過？ YES／NO') -ceq 'YES') | Format-List}
            '6' {Invoke-WsmValidation $p.Path $p.Hash $state (Read-WsmWizardValue 'Staged／Final') | Format-List}
            '7' {$dependency=Read-WsmWizardValue '跨主機 provider 證據索引（無必要相依留空）' -Optional;$dependencyHash='';if($dependency){$dependencyHash=Read-WsmWizardValue 'provider 索引可信 SHA256'};New-WsmCutoverPlan $p.Path $p.Hash $state (Read-WsmWizardValue '已審核 network JSON') (Read-WsmWizardValue 'network 可信 SHA256') (Read-WsmWizardValue '切換預覽輸出路徑') -DependencyEvidencePath $dependency -DependencyEvidenceHash $dependencyHash | Format-List}
            '8' {Invoke-WsmCutover $p.Path $p.Hash $state (Read-WsmWizardValue 'CutoverPlan JSON') (Read-WsmWizardValue '可信切換計畫 SHA256') (Read-WsmWizardValue ('輸入 CUTOVER '+$p.Package.Manifest.PairId)) | Format-List}
            '9' {Get-WsmAcceptanceGates $p.Path $p.Hash $state | Format-List}
            '10' {$preview=Get-WsmRollbackPreview $p.Path $p.Hash $state;$preview | Format-List;$preview.Rows | Format-Table;Invoke-WsmRollback $p.Path $p.Hash $state $preview.PreviewHash (Read-WsmWizardValue ('確認具體回復項目，輸入 ROLLBACK '+$p.Package.Manifest.PairId)) | Format-List}
            '11' {Repair-WsmOperation $p.Path $p.Hash $state | Format-List}
            '12' {Export-WsmStageResult $p.Path $p.Hash $state (Read-WsmWizardValue 'Restore／PreCutoverValidation／Cutover／PostCutoverValidation／Retirement') (Read-WsmWizardValue 'StageResult 輸出路徑') | Format-List}
            '13' {Export-WsmOperationReport $p.Path $p.Hash $state (Read-WsmWizardValue 'HTML 輸出路徑') | Format-List}
            default{Write-Host 'Invalid choice.'}
        }}finally{$secrets.Clear()}}
        '4' {Show-WsmMigrationMenu $Workspace}
        default{Write-Host 'Invalid role.'}
    }}catch [OperationCanceledException]{Write-Host $_.Exception.Message}catch{Write-Host ('操作失敗：'+$_.Exception.Message) -ForegroundColor Red}}
}
