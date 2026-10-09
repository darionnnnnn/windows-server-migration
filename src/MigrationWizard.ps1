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
function Read-WsmWizardGeneralHostEvidence($Package) {
    if($Package.Plan.SchemaVersion -ne 2){return}
    Write-Host '一般主機門檻使用 exact target／plan／phase 的可信證據；留空不解除未完成門檻。'
    while($true){
        $path=Read-WsmWizardValue 'GeneralHost 證據檔路徑（全部加入後留空）' -Optional
        if(-not $path){return}
        $hash=Read-WsmWizardValue '獨立可信證據 SHA256'
        Assert-WsmTrustedFile $path $hash
        [pscustomobject]@{Path=$path;SHA256=$hash}
    }
}
function Read-WsmWizardExternalReadinessReferences {
    Write-Host '切換需具備 SourceIdentityReleased、SourceWritersFenced、TargetIsolationConfirmed、ExternalNetworkFencing、NetworkOwnerApproval 五項 exact manifest 證據。'
    for($n=0;$n -lt 100;$n++) {
        $path=Read-WsmWizardValue 'ExternalReadinessEvidence JSON（全部加入後留空）' -Optional
        if(-not $path){return}
        $hash=Read-WsmWizardValue '獨立可信外部證據 SHA256'
        $record=Read-WsmTrustedJson $path $hash
        Assert-WsmEnvelope $record 'ExternalReadinessEvidence'
        [pscustomobject]@{Path=$path;SHA256=$hash;Check=[string]$record.Check;ItemId=[string]$record.ItemId}
    }
    throw 'External readiness evidence reference limit exceeded.'
}
function Initialize-WsmWizardTargetOutput([string]$WorkRoot) {
    $profilePath=Join-Path ([IO.Path]::GetFullPath($WorkRoot)) 'workspace-control\output-profile.json'
    if([IO.File]::Exists($profilePath)){return Initialize-WsmOutputWorkspace -WorkRoot $WorkRoot -Role Target}
    $mode=Read-WsmWizardValue '目標交付模式 Zip／Directory（需與來源一致；留空預設Zip）' -Optional
    if(-not $mode){$mode='Zip'}
    $arguments=@{WorkRoot=$WorkRoot;Role='Target';Mode=$mode}
    if($mode -ceq 'Zip'){$size=Read-WsmWizardValue '每卷上限 MiB（128–1024；留空512）' -Optional;$mib=512;if($size -and -not [int]::TryParse($size,[ref]$mib)){throw '每卷大小必須為整數 MiB。'};$arguments.VolumeBytes=[long]$mib*1048576}
    Initialize-WsmOutputWorkspace @arguments
}
function Read-WsmWizardValue([string]$Label,[switch]$Optional) {
    $value=Read-Host ($Label+'（0 取消；literal:0 表示文字 0）');if($null -eq $value){throw (New-Object IO.EndOfStreamException('Console input ended.'))};if($value -eq '0'){throw (New-Object OperationCanceledException('使用者取消，尚未提交本步驟。'))};if($value -ceq 'literal:0'){$value='0'};if(-not $Optional -and [string]::IsNullOrWhiteSpace($value)){throw 'Required value is blank.'};$value
}
function Select-WsmWizardPair([string]$Workspace) {
    $pairs=@((Get-WsmFleet $Workspace).Pairs);if(-not $pairs.Count){throw 'No host pairs registered.'};for($n=0;$n -lt $pairs.Count;$n++){Write-Host ('{0}. {1} -> {2} / Pair {3}' -f ($n+1),$pairs[$n].SourceName,$pairs[$n].TargetName,$pairs[$n].PairId)};$index=0;if(-not [int]::TryParse((Read-WsmWizardValue '配對編號'),[ref]$index) -or $index -lt 1 -or $index -gt $pairs.Count){throw 'Invalid pair choice.'};$pairs[$index-1].PairId
}
function Resolve-WsmManagerWizardAttempt([string]$WorkRoot,$Catalog,[string]$PairId) {
    $planHash=''
    if($Catalog.PSObject.Properties['Approval'] -and $Catalog.Approval -and $Catalog.Approval.PSObject.Properties['Kind'] -and $Catalog.Approval.Kind -ceq 'MigrationPlan' -and $Catalog.Approval.PSObject.Properties['Hash'] -and [string]$Catalog.Approval.Hash -match '^[a-fA-F0-9]{64}$'){$planHash=([string]$Catalog.Approval.Hash).ToLowerInvariant()}
    $attemptId=[Guid]::NewGuid().ToString('D')
    if($planHash){[void](Register-WsmOutputPair -WorkRoot $WorkRoot -Role Manager -PairId $PairId -PlanHash $planHash);$resolved=Resolve-WsmOutputWorkspace -WorkRoot $WorkRoot -Role Manager -PairId $PairId -PlanHash $planHash -AttemptId $attemptId}
    else{$resolved=Resolve-WsmOutputWorkspace -WorkRoot $WorkRoot -Role Manager -AttemptId $attemptId}
    [pscustomobject]@{Workspace=$resolved;AttemptId=$attemptId;PlanHash=$planHash;PendingPair=(-not [bool]$planHash)}
}
function Resolve-WsmSourceWizardWorkspace([string]$PlanPath,[string]$ExpectedHash,[string]$WorkRoot,[string]$AttemptId) {
    if([string]::IsNullOrWhiteSpace($WorkRoot)){throw 'A previously enrolled Source WorkRoot is required; run source inventory enrollment first.'}
    $profilePath=Join-Path (Join-Path ([IO.Path]::GetFullPath($WorkRoot)) 'workspace-control') 'output-profile.json'
    if(-not [IO.File]::Exists($profilePath)){throw 'Source WorkRoot has no saved OutputProfile; enroll it through source inventory before package or freeze operations.'}
    $plan=Read-WsmMigrationPlan $PlanPath $ExpectedHash
    $machine=Get-WsmMachineIdentity
    Assert-WsmMigrationHost $machine $plan.Source.Fingerprint
    $workspace=Initialize-WsmOutputWorkspace -WorkRoot $WorkRoot -Role Source
    if($workspace.Profile.Fingerprint -cne $plan.Source.Fingerprint -or $workspace.HostId -cne $plan.Source.HostId){throw 'MigrationPlan source identity does not match the enrolled Source WorkRoot; use the original inventory enrollment.'}
    $sourceStatePath=Join-Path $workspace.InventoryDirectory 'source-state.json'
    if(-not [IO.File]::Exists($sourceStatePath)){throw 'Enrolled Source inventory state is missing; restore the original inventory enrollment.'}
    $sourceState=Read-WsmJson $sourceStatePath
    if($sourceState.HostId -cne $plan.Source.HostId -or $sourceState.Fingerprint -cne $plan.Source.Fingerprint -or [long]$sourceState.Revision -lt 1){throw 'Enrolled Source inventory state is absent, stale, or bound to a different source; inventory must precede migration.'}
    [void](Register-WsmOutputPair -WorkRoot $WorkRoot -Role Source -PairId $plan.PairId -PlanHash $ExpectedHash)
    $attempt=Resolve-WsmOutputWorkspace -WorkRoot $WorkRoot -Role Source -PairId $plan.PairId -PlanHash $ExpectedHash -AttemptId $AttemptId
    [pscustomobject]@{Plan=$plan;Workspace=$workspace;Attempt=$attempt;SourceStateDirectory=$workspace.InventoryDirectory}
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
    $stateFull=[IO.Path]::GetFullPath($StateDirectory).TrimEnd('\');$stateWorkRoot=[IO.Path]::GetDirectoryName($stateFull)
    if($Role -ceq 'Target' -and $stateWorkRoot -and [IO.Path]::GetFileName($stateFull) -ieq 'pairs' -and [IO.File]::Exists((Join-Path (Join-Path $stateWorkRoot 'workspace-control') 'output-profile.json'))){
        $workspace=Initialize-WsmOutputWorkspace -WorkRoot $stateWorkRoot -Role Target
        if($workspace.StateDirectory -ine $stateFull){throw 'Target restore state directory differs from its enrolled OutputWorkspace.'}
        Register-WsmOutputPair -WorkRoot $stateWorkRoot -Role Target -PairId $manifest.PairId -PlanHash $manifest.PlanHash | Out-Null
    }
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
function Export-WsmWizardFullImportReceipt {
    param([string]$WorkRoot,[string]$AttemptId,[string]$TransportPath,[string]$TransportHash,[string]$ManifestPath,[string]$ManifestHash)
    $package=Test-WsmMigrationPackage $ManifestPath $ManifestHash
    $output=Resolve-WsmOutputWorkspace -WorkRoot $WorkRoot -Role Target -PairId $package.Manifest.PairId -PlanHash $package.Manifest.PlanHash -AttemptId $AttemptId
    Export-WsmImportedDeliveryReceipt -TransportPath $TransportPath -ExpectedHash $TransportHash -ManifestPath $ManifestPath -ExpectedManifestHash $ManifestHash -OutputDirectory (Join-Path $output.ReportsDirectory ('import-'+[Guid]::NewGuid().ToString('N')))
}
function Show-WsmMigrationWizard {
    param([string]$Workspace)
    while($true){Write-Host "`n遷移角色：1 管理工作區  2 來源本機  3 目標本機  4 進階操作請求  5 請求取消執行中的作業  6 測試主機驗證報告（複製貼回）  0 返回";$role=Read-Host '角色';if($null -eq $role){throw (New-Object IO.EndOfStreamException('Console input ended.'))};if($role -eq '0'){return};try{switch($role){
        '1' {Write-Host '1 產生逐項規格草稿  2 設定已檢查規格  3 核准隔離 pilot 遷移計畫  4 SID／帳號對應  5 工作區交易修復  6 批次規格草稿  7 批次規格預覽／提交  8 跨主機群組／資格矩陣操作  9 匯入交付／匯入收據  10 Windows 設定整類／逐項審核  0 返回';$step=Read-Host '操作';if($null -eq $step){throw (New-Object IO.EndOfStreamException('Console input ended.'))};if($step -eq '0'){continue};if($step -notin @('1','2','3','4','5','6','7','8','9','10')){Write-Host '無效選項；未修改。';continue};$managerWorkRoot=Read-WsmWizardValue '管理端固定 WorkRoot（專用輸出目錄，不要選已有 fleet.json 的舊管理工作區）';$managerEnrollment=Initialize-WsmOutputWorkspace -WorkRoot $managerWorkRoot -Role Manager;if($step -eq '9'){Import-WsmDeliveryReceipt -Workspace $Workspace -Path (Read-WsmWizardValue 'DeliveryReceipt JSON') -ExpectedHash (Read-WsmWizardValue '獨立可信收據 SHA256') | Format-List;continue};if($step -eq '10'){Invoke-WsmWindowsSettingsReviewWizard -Workspace $Workspace -PairId (Select-WsmWizardPair $Workspace) -SourceInventoryPath (Read-WsmWizardValue '原來源 Inventory JSON') -SourceInventoryHash (Read-WsmWizardValue '來源 Inventory 獨立可信 SHA256') -TargetInventoryPath (Read-WsmWizardValue '目標設定 Inventory JSON') -TargetInventoryHash (Read-WsmWizardValue '目標 Inventory 獨立可信 SHA256') | Format-List;continue};if($step -eq '8'){Show-WsmMigrationMenu $Workspace;continue};if($step -eq '5'){Repair-WsmWorkspace $Workspace | Format-List;continue};$pair=Select-WsmWizardPair $Workspace;$c=Get-WsmCatalog $Workspace $pair;$managerAttempt=Resolve-WsmManagerWizardAttempt $managerWorkRoot $c $pair;$managerReports=$managerAttempt.Workspace.ReportsDirectory;switch($step){
            '1' {$search=Read-WsmWizardValue '搜尋項目名稱' -Optional;Get-WsmItems $Workspace $pair -Search $search -PageSize 100 | Select-Object -ExpandProperty Items | Select-Object Name,Kind,ItemId | Format-Table;$itemId=Read-WsmWizardValue '完整 ItemId';$draftPath=Read-WsmWizardValue ('規格草稿 JSON 輸出路徑（留空使用 '+(Join-Path $managerReports ('migration-spec-'+$itemId+'.json'))+'）') -Optional;if(-not $draftPath){$draftPath=Join-Path $managerReports ('migration-spec-'+$itemId+'.json')};New-WsmMigrationSpecTemplate $Workspace $pair $itemId $draftPath | Format-List}
            '6' {$bundlePath=Read-WsmWizardValue ('批次規格 JSON 輸出路徑（留空使用 '+(Join-Path $managerReports 'migration-spec-bundle.json')+'）') -Optional;if(-not $bundlePath){$bundlePath=Join-Path $managerReports 'migration-spec-bundle.json'};Export-WsmMigrationSpecBundle $Workspace $pair $bundlePath -Category (Read-WsmWizardValue '類別（全部留空）' -Optional) -Search (Read-WsmWizardValue 'literal 搜尋（全部留空）' -Optional) | Format-List}
            '7' {$bundle=Read-WsmWizardValue '已填完且審核過的批次規格 JSON';$bundleHash=Read-WsmWizardValue '可信 bundle SHA256';$preview=Get-WsmMigrationSpecBundlePreview $Workspace $pair $bundle $bundleHash;$preview | Select-Object Selected,Invalid,Blocked,DecisionRevision | Format-List;$preview.Sample | Format-Table;$preview.Errors | Format-Table;if(-not $preview.Blocked){Import-WsmMigrationSpecBundle $Workspace $pair $bundle $bundleHash $preview.DecisionRevision (Read-WsmWizardValue '確認預覽的整批規格，輸入 APPLY-SPECS') | Format-List}}
            '4' {Set-WsmIdentityMap $Workspace $pair (Read-WsmWizardValue '已審核 IdentityMap JSON') (Read-WsmWizardValue '可信 SHA256') $c.DecisionRevision}
            '2' {Set-WsmMigrationSpec $Workspace $pair (Read-WsmWizardValue '完整 ItemId') (Read-WsmWizardValue '已填完且檢查過的規格 JSON') (Read-WsmWizardValue '可信規格 SHA256') $c.DecisionRevision}
            '3' {$approvedPath=Read-WsmWizardValue ('核准遷移計畫輸出路徑（留空使用 '+(Join-Path $managerReports 'approved-migration-plan.json')+'）') -Optional;if(-not $approvedPath){$approvedPath=Join-Path $managerReports 'approved-migration-plan.json'};$approved=Approve-WsmMigrationPlan $Workspace $pair (Read-WsmWizardValue '目標身分 JSON') (Read-WsmWizardValue '目標身分可信 SHA256') $approvedPath $c.DecisionRevision (Read-WsmWizardValue '尚未實機資格驗收，輸入 ISOLATED-PILOT 確认隔離測試');Register-WsmOutputPair -WorkRoot $managerWorkRoot -Role Manager -PairId $pair -PlanHash $approved.SHA256 | Out-Null;$approved | Format-List}
            default{Write-Host 'Invalid choice.'}
        }}
        '2' {Write-Host '1 空間／scope 預檢  2 匯出搬移包／重試  3 停寫及身分釋放記錄  4 依 OutputProfile 交付資料夾／分卷 ZIP  5 匯出來源結果  6 raw 證據索引  7 明確回復來源  8 排程中斷協調證據草稿  9 initial／final 差異 ZIP  10 來源設定檔審核草稿  11 核准設定檔即時差異報告  0 返回';$step=Read-Host '操作';if($null -eq $step){throw (New-Object IO.EndOfStreamException('Console input ended.'))};if($step -eq '0'){continue};if($step -eq '9'){Show-WsmDeltaWizard -Role Source;continue};if($step -eq '11'){Export-WsmConfigArtifactReview -PlanPath (Read-WsmWizardValue 'MigrationPlan JSON') -ExpectedHash (Read-WsmWizardValue '獨立可信計畫 SHA256') -Path (Read-WsmWizardValue '設定差異報告輸出路徑') | Format-List;continue};if($step -eq '10'){Export-WsmConfigArtifactScopeDraft -SpecPath (Read-WsmWizardValue '來源 FileScope 規格草稿 JSON') -ExpectedHash (Read-WsmWizardValue '可信規格 SHA256') -ItemId (Read-WsmWizardValue '來源完整 ItemId') -Path (Read-WsmWizardValue '設定檔審核草稿輸出路徑') | Format-List;continue};if($step -eq '6'){Export-WsmRawEvidenceManifest (Read-WsmWizardValue 'Inventory JSON') (Read-WsmWizardValue '可信 SHA256') (Read-WsmWizardValue 'raw 索引輸出路徑') | Format-List;continue};if($step -eq '5'){$p=Read-WsmWizardPackage;Export-WsmSourceStageResult $p.Path $p.Hash (Read-WsmWizardValue '來源受控狀態目錄') (Read-WsmWizardValue 'Export／FinalDelta') (Read-WsmWizardValue 'StageResult 輸出路徑') | Format-List;continue};if($step -eq '4'){$output=Read-WsmWizardValue '來源固定 WorkRoot（沿用盤點 enrollment；交付方式採已儲存 OutputProfile）';$p=Read-WsmWizardRestorePackage $output Source;$attempt=Read-WsmWizardValue '既有 AttemptId（接續必填；新交付留空）' -Optional;Export-WsmEnrolledPackageDelivery -WorkRoot $output -ManifestPath $p.Path -ExpectedHash $p.Hash -AttemptId $attempt -CancellationToken $p.CancellationToken | Format-List;continue};$plan=Read-WsmWizardValue 'MigrationPlan JSON';$hash=Read-WsmWizardValue '獨立可信計畫 SHA256';switch($step){
            '1' {$sourceRoot=Read-WsmWizardValue '既有 Source WorkRoot（需先完成來源盤點 enrollment）';$sourceContext=Resolve-WsmSourceWizardWorkspace $plan $hash $sourceRoot '';Get-WsmPackageEstimate $plan $hash $sourceContext.Attempt.PackagesDirectory | Format-List}
            '2' {$sourceRoot=Read-WsmWizardValue '既有 Source WorkRoot（需先完成來源盤點 enrollment）';$attemptId=Read-WsmWizardValue '新 AttemptId 留空；接續既有封存嘗試時輸入其 AttemptId' -Optional;$sourceContext=Resolve-WsmSourceWizardWorkspace $plan $hash $sourceRoot $attemptId;$base=Read-WsmWizardValue 'final delta 的基底 manifest（初始包留空）' -Optional;$baseHash='';$freeze='';$freezeHash='';if($base){$baseHash=Read-WsmWizardValue '基底可信 SHA256'};$freeze=Read-WsmWizardValue '停寫記錄（mutable／final 必填）' -Optional;if($freeze){$freezeHash=Read-WsmWizardValue '停寫記錄可信 SHA256'};$freezeExternalPath='';$freezeExternalHash='';if($freeze){$freezeExternalPath=Read-WsmWizardValue '原 SourceFreezeReady 外部證據 JSON（擷取前會重驗本機材料）';$freezeExternalHash=Read-WsmWizardValue 'SourceFreezeReady 獨立可信 SHA256'};$token=New-WsmWizardCancellation $sourceContext.Plan.PairId $hash '' $sourceContext.SourceStateDirectory;Export-WsmMigrationPackage $plan $hash $sourceContext.SourceStateDirectory $sourceContext.Attempt.PackagesDirectory -BaseManifestPath $base -BaseManifestHash $baseHash -FreezePath $freeze -FreezeHash $freezeHash -FreezeExternalEvidencePath $freezeExternalPath -FreezeExternalEvidenceHash $freezeExternalHash -CancellationToken $token | Format-List}
            '7' {$sourceRoot=Read-WsmWizardValue '既有 Source WorkRoot（需先完成來源盤點 enrollment）';$attemptId=Read-WsmWizardValue 'Source AttemptId（來源恢復使用其配對目錄；留空建立新嘗試）' -Optional;$sourceContext=Resolve-WsmSourceWizardWorkspace $plan $hash $sourceRoot $attemptId;$attempt=Read-WsmWizardValue 'SourceAttempt JSON';$attemptHash=Read-WsmWizardValue 'SourceAttempt 可信 SHA256';$owner=Read-WsmWizardValue '責任人';$proof=Read-WsmWizardValue '目標停寫／資料協調／來源取得唯一寫入權的證據';$resumeEvidencePath=Read-WsmWizardValue 'SourceResumeReady 外部所有權恢復 JSON';$resumeEvidenceHash=Read-WsmWizardValue 'SourceResumeReady JSON 可信 SHA256';$taskProof=Read-WsmWizardValue 'SourceTaskReconciliation JSON（原本執行中排程必填；無則留空）' -Optional;$taskProofHash='';if($taskProof){$taskProofHash=Read-WsmWizardValue '排程工作協調證據可信 SHA256'};$approved=$sourceContext.Plan;$ack='SOURCE-OWNERSHIP-RESTORED '+$approved.PairId;Invoke-WsmSourceResume $plan $hash $attempt $attemptHash $sourceContext.SourceStateDirectory $owner $proof $ack -TaskReconciliationPath $taskProof -TaskReconciliationHash $taskProofHash -ResumeExternalEvidencePath $resumeEvidencePath -ResumeExternalEvidenceHash $resumeEvidenceHash -WhatIf | Format-List;Invoke-WsmSourceResume $plan $hash $attempt $attemptHash $sourceContext.SourceStateDirectory $owner $proof (Read-WsmWizardValue ('核對原始啟用狀態後輸入 '+$ack)) -TaskReconciliationPath $taskProof -TaskReconciliationHash $taskProofHash -ResumeExternalEvidencePath $resumeEvidencePath -ResumeExternalEvidenceHash $resumeEvidenceHash | Format-List}
            '8' {Export-WsmSourceTaskReconciliationTemplate -PlanPath $plan -ExpectedHash $hash -SourceAttemptPath (Read-WsmWizardValue '目前 SourceAttempt JSON') -SourceAttemptHash (Read-WsmWizardValue '目前 attempt 可信 SHA256') -Path (Read-WsmWizardValue '協調證據草稿輸出 JSON') | Format-List}
            '3' {$sourceRoot=Read-WsmWizardValue '既有 Source WorkRoot（需先完成來源盤點 enrollment）';$attemptId=Read-WsmWizardValue '既有 Source AttemptId（接續必填；新凍結留空）' -Optional;$sourceContext=Resolve-WsmSourceWizardWorkspace $plan $hash $sourceRoot $attemptId;$released=(Read-WsmWizardValue '舊 hostname／IP 已釋放？ YES／NO') -ceq 'YES';$freezeEvidencePath=Read-WsmWizardValue 'SourceFreezeReady 外部 writer fence JSON';$freezeEvidenceHash=Read-WsmWizardValue 'SourceFreezeReady JSON 可信 SHA256';$freezeEvidence=Read-WsmTrustedJson $freezeEvidencePath $freezeEvidenceHash;if($freezeEvidence.Kind -cne 'ExternalReadinessEvidence' -or $freezeEvidence.Phase -cne 'SourceFreezeReady' -or -not $freezeEvidence.FreezeEpoch){throw 'A hash-trusted SourceFreezeReady evidence record with a FreezeEpoch is required.'};$freezeEpoch=[string]$freezeEvidence.FreezeEpoch;$previous=Read-WsmWizardValue '前次 SourceAttempt（中斷重試留原始基準；首次留空）' -Optional;$previousHash='';if($previous){$previousHash=Read-WsmWizardValue '前次 attempt 可信 SHA256'};$release='';if($released){$release=Read-WsmWizardValue '身分／IP／網域釋放的獨立證據'};$freezePath=Join-Path $sourceContext.Attempt.ReportsDirectory 'freeze.json';Export-WsmFreezeRecord $plan $hash $freezePath (Read-WsmWizardValue '服務責任人') (Read-WsmWizardValue '停寫與外部 writer 驗證證據') (Read-WsmWizardValue '輸入 OWNER-CONFIRMED-QUIESCENCE') -SourceStateDirectory $sourceContext.SourceStateDirectory -SourceIdentityReleased:$released -ReleaseEvidence $release -PreviousAttemptPath $previous -PreviousAttemptHash $previousHash -FreezeExternalEvidencePath $freezeEvidencePath -FreezeExternalEvidenceHash $freezeEvidenceHash -FreezeEpoch $freezeEpoch | Format-List}
            default{Write-Host 'Invalid choice.'}
        }}
        '3' {Write-Host '1 登記目標固定身分  2 匯入完整 ZIP／Directory  3 還原預覽  4 還原／重試  5 驗收證據  6 設定／業務驗證  7 產生切換預覽  8 明確執行切換  9 完成／退役門檻  10 回復預覽／執行  11 修復 checkpoint  12 匯出結果  13 遷移報告  14 中斷啟用的審核接續  15 增量匯入／套用／修復  0 返回';$step=Read-Host '操作';if($null -eq $step){throw (New-Object IO.EndOfStreamException('Console input ended.'))};if($step -eq '0'){continue};if($step -eq '15'){Show-WsmDeltaWizard -Role Target;continue};$workRoot=Read-WsmWizardValue '目標固定 WorkRoot（配對、operation state、套件與 transport 都由此隔離保存）';$enrolled=Initialize-WsmWizardTargetOutput $workRoot;$state=$enrolled.StateDirectory;if($step -eq '1'){Register-WsmTarget $state (Read-WsmWizardValue '目標身分 JSON 輸出副本路徑') | Format-List;continue};if($step -eq '2'){if($enrolled.Profile.Mode -ceq 'Directory'){$summaryPath=Read-WsmWizardValue 'DirectoryDelivery 封存摘要 JSON';$summaryHash=Read-WsmWizardValue '獨立可信摘要 SHA256';$sourceDirectory=Read-WsmWizardValue '實際已搬到本機的封存 Directory 路徑';$summary=Read-WsmTrustedJson $summaryPath $summaryHash;Assert-WsmEnvelope $summary 'DirectoryDelivery';$token=New-WsmWizardCancellation $summary.PairId $summary.PlanHash $summary.ManifestHash $workRoot;$imported=Import-WsmDirectoryDelivery -SummaryPath $summaryPath -ExpectedSummaryHash $summaryHash -SourceDirectory $sourceDirectory -WorkRoot $workRoot -AttemptId (Read-WsmWizardValue '既有 AttemptId（新匯入留空）' -Optional) -CancellationToken $token;$imported | Format-List;Export-WsmWizardFullImportReceipt $workRoot $imported.AttemptId $summaryPath $summaryHash $imported.ManifestPath $imported.ManifestHash | Format-List;continue};$transport=Read-WsmWizardValue 'transport.json';$transportHash=Read-WsmWizardValue '獨立可信 transport SHA256';$t=Read-WsmTrustedJson $transport $transportHash;Assert-WsmEnvelope $t 'PackageTransport';$targetOutput=Resolve-WsmOutputWorkspace -WorkRoot $workRoot -Role Target -PairId $t.PairId -PlanHash $t.PlanHash;if($targetOutput.AttemptProfile.Mode -cne 'Zip'){throw 'This package ZIP importer requires the enrolled ZIP OutputProfile; no mode fallback is permitted.'};$output=$targetOutput.PackagesDirectory;$token=New-WsmWizardCancellation $t.PairId $t.PlanHash $t.ManifestHash $output;$imported=Import-WsmPackageZip $transport $transportHash $output -CancellationToken $token;$imported | Format-List;Export-WsmWizardFullImportReceipt $workRoot $targetOutput.AttemptId $transport $transportHash $imported.ManifestPath $imported.SHA256 | Format-List;continue};$p=$null;if($step -in @('3','4')){$p=Read-WsmWizardRestorePackage $state}else{$p=Read-WsmWizardPackage};$operationWorkspace=Register-WsmOutputPair -WorkRoot $workRoot -Role Target -PairId $p.Package.Manifest.PairId -PlanHash $p.Package.Manifest.PlanHash;$generalEvidence=@();if($step -in @('3','4','6','7','8','9','12','14')){$generalEvidence=@(Read-WsmWizardGeneralHostEvidence $p.Package)};$secrets=@{};try{switch($step){
            '3' {$secrets=Read-WsmWizardSecrets $p.Package;Get-WsmRestorePreview $p.Path $p.Hash $state $secrets $p.CancellationToken -GeneralHostEvidence $generalEvidence | Format-List}
            '4' {$secrets=Read-WsmWizardSecrets $p.Package;$preview=Get-WsmRestorePreview $p.Path $p.Hash $state $secrets $p.CancellationToken -GeneralHostEvidence $generalEvidence;$preview.Rows | Format-Table;$preview.Problems | Format-Table;if((Read-WsmWizardValue ('確認 Pair '+$p.Package.Manifest.PairId+'，輸入 RESTORE')) -ceq 'RESTORE'){Invoke-WsmRestore $p.Path $p.Hash $state $secrets -CancellationToken $p.CancellationToken -GeneralHostEvidence $generalEvidence | Format-List}}
            '5' {$itemId=Read-WsmWizardValue 'ItemId（全機門檻留空）' -Optional;$check=Read-WsmWizardValue 'Check（BusinessStaged／BusinessFinal／ManualRestore／DNS／Kerberos／ExternalConnectivity／Monitoring／BackupRestore／LongCycleJobs／SecurityAgent／License／UserAcceptance／Observation／RollbackReconcile／RetirementRetention；退役另含各項 Handoff 與 RollbackCutoffAndDeletionOwner）';$owner=Read-WsmWizardValue '負責人';$description=Read-WsmWizardValue '驗收方法／預期／實際／證據參考';$externalPath=Read-WsmWizardValue 'ExternalReadinessEvidence JSON（文字確認無法通過門檻）';$externalHash=Read-WsmWizardValue '獨立可信外部證據 SHA256';$passed=(Read-WsmWizardValue '實際通過？ YES／NO') -ceq 'YES';Set-WsmValidationEvidence $p.Path $p.Hash $state $itemId $check $owner $description $passed -ExternalEvidencePath $externalPath -ExternalEvidenceHash $externalHash | Format-List}
            '6' {Invoke-WsmValidation $p.Path $p.Hash $state (Read-WsmWizardValue 'Staged／Final') -GeneralHostEvidence $generalEvidence | Format-List}
            '7' {$dependency=Read-WsmWizardValue '跨主機 provider 證據索引（無必要相依留空）' -Optional;$groupIndex=Read-WsmWizardValue '跨主機一致性群組索引（無群組留空）' -Optional;$groupHash='';if($groupIndex){$groupHash=Read-WsmWizardValue '群組索引可信 SHA256'};$dependencyHash='';if($dependency){$dependencyHash=Read-WsmWizardValue 'provider 索引可信 SHA256'};$externalReferences=@(Read-WsmWizardExternalReadinessReferences);New-WsmCutoverPlan $p.Path $p.Hash $state (Read-WsmWizardValue '已審核 network JSON') (Read-WsmWizardValue 'network 可信 SHA256') (Read-WsmWizardValue '切換預覽輸出路徑') -DependencyEvidencePath $dependency -DependencyEvidenceHash $dependencyHash -GroupEvidenceIndexPath $groupIndex -GroupEvidenceIndexHash $groupHash -GeneralHostEvidence $generalEvidence -ExternalEvidenceReferences $externalReferences | Format-List}
            '8' {if((Read-WsmWizardValue '改名需要網域認證？ YES／NO') -ceq 'YES'){$credential=Get-Credential -Message 'DomainRename：核准的網域改名認證，只保留在記憶體';if(-not $credential){throw (New-Object OperationCanceledException('Credential entry cancelled.'))};$secrets.DomainRename=$credential};Invoke-WsmCutover $p.Path $p.Hash $state (Read-WsmWizardValue 'CutoverPlan JSON') (Read-WsmWizardValue '可信切換計畫 SHA256') (Read-WsmWizardValue ('輸入 CUTOVER '+$p.Package.Manifest.PairId)) -Secrets $secrets -GeneralHostEvidence $generalEvidence | Format-List}
            '9' {Get-WsmAcceptanceGates $p.Path $p.Hash $state -GeneralHostEvidence $generalEvidence | Format-List}
            '10' {$preview=Get-WsmRollbackPreview $p.Path $p.Hash $state;$preview | Format-List;$preview.Rows | Format-Table;Invoke-WsmRollback $p.Path $p.Hash $state $preview.PreviewHash (Read-WsmWizardValue ('確認具體回復項目，輸入 ROLLBACK '+$p.Package.Manifest.PairId)) | Format-List}
            '11' {Repair-WsmOperation $p.Path $p.Hash $state | Format-List}
            '12' {Export-WsmStageResult $p.Path $p.Hash $state (Read-WsmWizardValue 'Restore／PreCutoverValidation／Cutover／PostCutoverValidation／Retirement') (Read-WsmWizardValue 'StageResult 輸出路徑') -GeneralHostEvidence $generalEvidence | Format-List}
            '14' {Invoke-WsmCutover $p.Path $p.Hash $state (Read-WsmWizardValue '原核准 CutoverPlan JSON') (Read-WsmWizardValue '可信切換計畫 SHA256') (Read-WsmWizardValue ('輸入 CUTOVER '+$p.Package.Manifest.PairId)) -ResumeActivation -ResumeOwner (Read-WsmWizardValue '啟用接續責任人') -ResumeEvidence (Read-WsmWizardValue '已協調可能新增交易、確認來源仍停寫與啟用接續的證據') -GeneralHostEvidence $generalEvidence | Format-List}
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
        $confirmationPath=Read-WsmWizardValue -Optional '可選環境確認 JSON 路徑（只作報告參考，不是核准或 readiness proof）'
        if($confirmationPath){$confirmationHash=Read-WsmWizardValue '環境確認 JSON 的獨立可信 SHA256';$arguments.EnvironmentConfirmationReferences=@([pscustomobject]@{Path=$confirmationPath;SHA256=$confirmationHash})}
    }elseif($mode -cne '1'){throw (New-WsmContractError 'Invalid lab report mode.')}
    Export-WsmLabValidationReport @arguments | Format-List
    Write-Host '開啟回傳的文字報告，將完整區塊複製貼回；保留 JSON 與 SHA256。NotTested／Blocked 不代表驗證通過。'
}
