#requires -Version 5.1
# N5：反例測試（16.6-10、16.3-6）。
#   16.6-10  同一個路徑被換成另一包（不同 PackageId／Generation 但路徑相同）時，匯入與續作（耐久作業紀錄解析）必須拒絕，且不留下可當成授權的匯入狀態。
#   16.3-6   read-only 匯入（Target 端只驗證、不執行）的結果與 CLI／HTML 投影，不得宣稱 ProductionExecutionEnabled 或 ProductionVerified 為 true。
# 用的是真正的封裝驗證、ZIP／資料夾交付與 Target 匯入入口；只替身化 Target 的本機身分。
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-n5-import-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
# Target WorkRoot 要夠短（資料夾交付的成員路徑有 MAX_PATH 上限），與 Test-OfflineFullSet 一樣放在 C:\Users\Public 底下的隨機短名稱。
$work=Join-Path 'C:\Users\Public' ('d'+[Guid]::NewGuid().ToString('N').Substring(0,6))
if([IO.File]::Exists($work) -or [IO.Directory]::Exists($work)){throw 'Refusing to use a pre-existing randomized Target test directory.'}
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root,$Work)
        $script:checks=0
        function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
        function RejectLike([scriptblock]$Action,[string]$Pattern,[string]$Message){$actual='';try{& $Action|Out-Null}catch{$actual=$_.Exception.Message};Check ([bool]$actual -and $actual -like $Pattern) ($Message+' [actual: '+$actual+']')}
        function SaveJson($Data,[string]$Path){[IO.File]::WriteAllText($Path,($Data|ConvertTo-Json -Depth 100 -Compress),(New-Object Text.UTF8Encoding($false)));$Path}
        function Sha([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}

        # ---- Target 身分是唯一的替身；計畫、封裝、交付、匯入、解析全是核心程式。
        $target=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString('D');Fingerprint=('b'*64);Name='Import identity Target';OS='Fixture Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}
        function script:Get-WsmMachineIdentity {$script:importTarget}
        $script:importTarget=$target
        $enrollment=Initialize-WsmOutputWorkspace -WorkRoot $Work -Role Target
        Initialize-WsmWorkspace $Work|Out-Null
        $pair=[Guid]::NewGuid().ToString('D')
        $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString('D');Fingerprint=('a'*64);Name='Import identity Source';OS='Fixture Server';Version='10.0'}
        $item=New-WsmItem $source.HostId Storage DataRoot 'Import identity fixture' 'import-identity-fixture' @{Path='C:\fixture\import-identity'}
        foreach($name in @('Decision','Reason','Owner','Evidence')){$value=switch($name){Decision{'Include'}Reason{'Reviewed fixture package'}Owner{'Fixture owner'}Evidence{'Isolated import identity test'}};$item|Add-Member NoteProperty $name $value -Force}
        $scope=Join-Path $Root 'payload-scope';[void][IO.Directory]::CreateDirectory($scope)
        $targetScope=Join-Path $Root 'target-scope'
        $spec=[pscustomobject][ordered]@{Adapter='FileScope';Product='Fixture';Procedure='Inspect test payload';Artifacts=@();BusinessChecks=@('Confirm fixture bytes');Owner='Fixture owner';Evidence='Isolated test';SourcePath=$scope;TargetPath=$targetScope;ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='Exact';ConflictPolicy='Block';TransferChannel='C';ContentSelection='WholeScope';ConfigFiles=@();ConfigOverrides=@()}
        $item|Add-Member NoteProperty MigrationSpec $spec -Force
        $snapshot=New-WsmInventory $source 1 @($item);$snapshotPath=Join-Path $Root 'source-inventory.json';SaveJson $snapshot $snapshotPath|Out-Null
        $snapshotHash=Sha $snapshotPath
        $planItem=$item|ConvertTo-Json -Depth 50|ConvertFrom-Json
        $plan=[pscustomobject][ordered]@{SchemaVersion=3;ToolVersion=$script:ToolVersion;Kind='MigrationPlan';BatchId=[Guid]::NewGuid().ToString('D');PairId=$pair;ApprovalId=[Guid]::NewGuid().ToString('D');Source=$source;Target=[pscustomobject]@{HostId=$enrollment.Profile.HostId;Fingerprint=$target.Fingerprint;Name=$target.Name;OS=$target.OS;Version=$target.Version};InventoryRevision=1;DecisionRevision=2;InventoryHash=$snapshotHash;ImportedUtc=(Get-WsmUtc);Mode='IsolatedPilot';ToolFingerprint=(Get-WsmToolFingerprint);ApprovedUtc=(Get-WsmUtc);Items=@($planItem);ScopeMode='Assistive'}
        $plan|Add-Member NoteProperty Assistive ([pscustomobject][ordered]@{ContractVersion=1;PairId=$pair;SourceSnapshotHash=$snapshotHash;SourcePolicy='SourceCOnly';SourceSelectionsVersion=1;ApprovedItemIds=@([string]$item.ItemId);MaterialReferences=@();DiscoveryAuthority=[pscustomobject][ordered]@{SourceSnapshotReference=[pscustomobject][ordered]@{Reference='source-inventory.json';SHA256=$snapshotHash;InventoryRevision=1;CreatedUtc=(Get-WsmUtc)};InventoryRevision=1;SelectionRevision=1;Dispositions=@([pscustomobject][ordered]@{ItemId=[string]$item.ItemId;Selected=$true;Decision='Include';Reason='Explicitly selected test fixture'})}}) -Force
        Assert-WsmAssistiveContract $plan MigrationPlan|Out-Null
        $planPath=Join-Path $Root 'approved-plan.json';SaveJson $plan $planPath|Out-Null
        $planHash=Sha $planPath
        $planImport=Import-WsmWizardApprovedPlan -Workspace $Work -Role Target -Path $planPath -ExpectedHash $planHash
        Check ($planImport.Status -ceq 'ImportedVerified' -and $planImport.PairId -ceq $pair) 'Target did not receive the real approved schema-3 fixture plan.'
        $proof=Assert-WsmAssistiveSourceScope $spec SourceCOnly -Native
        Check ($proof.Channel -ceq 'C') 'The bounded package fixture was not on the native C volume.'

        # ---- 兩個真正封印的封裝：同一個 Pair 與計畫、不同的 PackageId，P2 是 Generation 2（承接 P1），內容位元組也不同。
        $script:packageNumber=0
        function New-FixturePackage([int]$Generation,[string]$BaseManifestHash){
            $script:packageNumber++;$packageRoot=Join-Path $Root ('package-'+$script:packageNumber);$payloadRoot=Join-Path $packageRoot 'payload';[void][IO.Directory]::CreateDirectory($payloadRoot)
            [IO.File]::Copy($planPath,(Join-Path $packageRoot 'plan.json'))
            $bytes=New-Object byte[] (2*1024*1024);$rng=[Security.Cryptography.RandomNumberGenerator]::Create();try{$rng.GetBytes($bytes)}finally{$rng.Dispose()}
            $sourceFile=Join-Path $scope 'state.bin';[IO.File]::WriteAllBytes($sourceFile,$bytes)
            $fileMetadata=Get-WsmFileMetadata $sourceFile 'DaclOwner'
            $blob=Write-WsmPayloadFile $sourceFile $payloadRoot 65536 0 $null
            $record=[pscustomobject][ordered]@{ItemId=[string]$item.ItemId;RelativePath='state.bin';Directory=$false;Metadata=$fileMetadata;Data=$blob}
            $recordsPath=Join-Path $packageRoot 'artifacts.jsonl';[IO.File]::WriteAllText($recordsPath,(ConvertTo-Json -InputObject $record -Depth 30 -Compress)+"`n",(New-Object Text.UTF8Encoding($false)))
            $manifest=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='MigrationPackage';PackageId=[Guid]::NewGuid().ToString('D');BatchId=$plan.BatchId;PairId=$pair;ApprovalId=$plan.ApprovalId;PlanHash=$planHash;Source=$plan.Source;Target=$plan.Target;InventoryRevision=1;DecisionRevision=2;Generation=$Generation;BaseManifestHash=$BaseManifestHash;Final=$false;FreezeHash='';ArtifactsHash=(Sha $recordsPath);Files=1;Bytes=[long]$bytes.Length;Records=1;ChunkBytes=65536;SealedUtc=(Get-WsmUtc);Mode='IsolatedPilot';SourceCollectionProofs=@([pscustomobject][ordered]@{ItemId=[string]$item.ItemId;Channel='C';PhysicalPath=$proof.PhysicalPath;SourceCPhysicalRoot=$proof.SourceCPhysicalRoot;SourceFingerprint=$source.Fingerprint;NativeVerified=$true})}
            $manifestPath=Join-Path $packageRoot 'manifest.json';SaveJson $manifest $manifestPath|Out-Null
            $manifestHash=Sha $manifestPath
            $validated=Test-WsmMigrationPackage $manifestPath $manifestHash
            Check ($validated.Valid -and [int]$validated.Manifest.Generation -eq $Generation) ('Core validator rejected fixture package '+$script:packageNumber+'.')
            [pscustomobject]@{Root=$packageRoot;ManifestPath=$manifestPath;ManifestHash=$manifestHash;PackageId=[string]$manifest.PackageId;Generation=$Generation}
        }
        $p1=New-FixturePackage 1 ''
        $p2=New-FixturePackage 2 $p1.ManifestHash
        $p1b=New-FixturePackage 1 ''
        Check ($p1.PackageId -cne $p2.PackageId -and $p1.PackageId -cne $p1b.PackageId -and $p1.ManifestHash -cne $p2.ManifestHash -and $p1.ManifestHash -cne $p1b.ManifestHash) 'Fixture packages are not three distinct sealed identities.'
        function Copy-TreeOver([string]$From,[string]$To){foreach($file in @(Get-ChildItem -LiteralPath $From -Recurse -File)){$relative=$file.FullName.Substring($From.TrimEnd('\').Length).TrimStart('\');$destination=Join-Path $To $relative;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination));[IO.File]::Copy($file.FullName,$destination,$true)}}
        function Restore-Tree([string]$From,[string]$To){foreach($entry in @(Get-ChildItem -LiteralPath $To -Force)){Remove-Item -LiteralPath $entry.FullName -Recurse -Force};Copy-TreeOver $From $To}
        function Get-ImportDirectories(){$importRoot=Join-Path (Join-Path $Work 'workspace-control') 'wizard-package-imports';if([IO.Directory]::Exists($importRoot)){@(Get-ChildItem -LiteralPath $importRoot -Directory|ForEach-Object Name)}else{@()}}
        function Get-AttemptDirectories(){$attemptRoot=Join-Path $Work 'workspace-control';@(Get-ChildItem -LiteralPath $attemptRoot -Recurse -Directory -ErrorAction SilentlyContinue|ForEach-Object {$_.FullName.Substring($attemptRoot.Length)})}
        function Assert-NoPackageAuthority([string]$Label){
            $message='';try{$null=Get-WsmWizardTargetPackage -Workspace $Work -PairId $pair -Context (Assert-WsmWizardTargetRole $Work $pair) -Jobs @()}catch{$message=$_.Exception.Message}
            Check ($message -like 'No durable successful Target package-delivery job*') ($Label+': a refused import left a resolvable authoritative package state ('+$message+').')
        }

        # ======================================================================== 16.6-10 匯入：資料夾交付
        $delivery1=Export-WsmDirectoryDelivery -ManifestPath $p1.ManifestPath -ExpectedHash $p1.ManifestHash -OutputDirectory (Join-Path $Root 'delivery-1')
        $delivery2=Export-WsmDirectoryDelivery -ManifestPath $p2.ManifestPath -ExpectedHash $p2.ManifestHash -OutputDirectory (Join-Path $Root 'delivery-2')
        $delivery1Original=Join-Path $Root 'delivery-1-original';Copy-TreeOver $delivery1.Directory $delivery1Original
        Check ($delivery1.SummarySHA256 -cne $delivery2.SummarySHA256) 'Directory delivery summaries of two different packages are identical.'
        # P1 的交付資料夾路徑不變，內容整包換成 P2（不同 PackageId 與 Generation）。摘要與預期雜湊仍是 P1 的。
        Copy-TreeOver $delivery2.Directory $delivery1.Directory
        $swapOperation=[Guid]::NewGuid().ToString('D')
        RejectLike {Import-WsmWizardTargetDirectoryPackage -Workspace $Work -PairId $pair -SummaryPath $delivery1.SummaryPath -ExpectedSummaryHash $delivery1.SummarySHA256 -SourceDirectory $delivery1.Directory -OperationId $swapOperation} '*' 'The formal Target directory importer accepted a different package placed at the delivery path of the first.'
        Assert-NoPackageAuthority 'Directory swap'
        # 還原原本的 P1 交付內容（同一路徑）：正常匯入成功，證明上面的拒絕確實來自內容被換，而不是環境問題。
        Restore-Tree $delivery1Original $delivery1.Directory
        $import1Operation=[Guid]::NewGuid().ToString('D')
        $import1=Import-WsmWizardTargetDirectoryPackage -Workspace $Work -PairId $pair -SummaryPath $delivery1.SummaryPath -ExpectedSummaryHash $delivery1.SummarySHA256 -SourceDirectory $delivery1.Directory -OperationId $import1Operation
        Check ($import1.Status -ceq 'Succeeded' -and $import1.Valid -and [string]$import1.ManifestHash -ceq $p1.ManifestHash) 'Control: the genuine first package did not import through the formal Target directory importer.'

        # ======================================================================== 16.6-10 匯入：ZIP 交付
        $zip1=Export-WsmPackageZip -ManifestPath $p1.ManifestPath -ExpectedHash $p1.ManifestHash -OutputDirectory (Join-Path $Root 'zip-1') -VolumeBytes 1048576
        $zip2=Export-WsmPackageZip -ManifestPath $p2.ManifestPath -ExpectedHash $p2.ManifestHash -OutputDirectory (Join-Path $Root 'zip-2') -VolumeBytes 1048576
        $zip1Directory=Split-Path -Parent $zip1.Path;$zip2Directory=Split-Path -Parent $zip2.Path
        $zip1Original=Join-Path $Root 'zip-1-original';Copy-TreeOver $zip1Directory $zip1Original
        $zipTransport1=Read-WsmTrustedJson $zip1.Path ([string]$zip1.SHA256);$zipTransport2=Read-WsmTrustedJson $zip2.Path ([string]$zip2.SHA256)
        Check ($zip1.SHA256 -cne $zip2.SHA256 -and $zipTransport1.PackageId -cne $zipTransport2.PackageId) 'ZIP transports of two different packages are identical.'
        # (a) 描述檔與卷整組被換成 P2，路徑不變；預期雜湊仍是 P1 的描述檔雜湊。
        Copy-TreeOver $zip2Directory $zip1Directory
        $zipOperationA=[Guid]::NewGuid().ToString('D')
        RejectLike {Import-WsmWizardTargetZipPackage -Workspace $Work -PairId $pair -TransportPath $zip1.Path -ExpectedHash ([string]$zip1.SHA256) -OperationId $zipOperationA} '*' 'The formal Target ZIP importer accepted a different package placed at the transport path of the first.'
        # (b) 描述檔維持 P1 的，只把卷檔案換成 P2 的位元組（檔名維持 P1 的）。
        Restore-Tree $zip1Original $zip1Directory
        foreach($index in 0..([Math]::Min($zipTransport1.Volumes.Count,$zipTransport2.Volumes.Count)-1)){[IO.File]::Copy((Join-Path $zip2Directory $zipTransport2.Volumes[$index].Name),(Join-Path $zip1Directory $zipTransport1.Volumes[$index].Name),$true)}
        Check ((Sha (Join-Path $zip1Directory $zipTransport1.Volumes[0].Name)) -cne [string]$zipTransport1.Volumes[0].Hash) 'ZIP swap fixture: the first volume was not actually replaced.'
        $zipOperationB=[Guid]::NewGuid().ToString('D')
        RejectLike {Import-WsmWizardTargetZipPackage -Workspace $Work -PairId $pair -TransportPath $zip1.Path -ExpectedHash ([string]$zip1.SHA256) -OperationId $zipOperationB} '*' 'The formal Target ZIP importer accepted volumes of a different package under the first package descriptor.'
        Check (@(Get-ImportDirectories|Where-Object {$_ -ceq $zipTransport1.PackageId -or $_ -ceq $zipTransport2.PackageId}).Count -eq 0) 'A refused ZIP swap created a package import state directory.'
        Restore-Tree $zip1Original $zip1Directory

        # ======================================================================== 16.3-6 read-only 匯入不宣稱 ProductionExecutionEnabled
        function Assert-NoProductionClaim($Value,[string]$Where){
            $json=ConvertTo-Json -InputObject $Value -Depth 30 -Compress
            Check ($json -notmatch '"ProductionExecutionEnabled"\s*:\s*true' -and $json -notmatch '"ProductionVerified"\s*:\s*true' -and $json -notmatch '"ProductionQualified"\s*:\s*true' -and $json -notmatch '"ReadinessProof"\s*:\s*true') ($Where+' claims production execution, verification or readiness: '+$json.Substring(0,[Math]::Min(300,$json.Length)))
            if($Value.PSObject.Properties['ProductionVerified']){Check ($Value.ProductionVerified -eq $false) ($Where+' did not keep ProductionVerified false.')}
            if($Value.PSObject.Properties['ProductionExecutionEnabled']){Check ($Value.ProductionExecutionEnabled -eq $false) ($Where+' set ProductionExecutionEnabled to something other than false.')}
        }
        $zipImportOperation=[Guid]::NewGuid().ToString('D')
        $zipImport=Import-WsmWizardTargetZipPackage -Workspace $Work -PairId $pair -TransportPath $zip1.Path -ExpectedHash ([string]$zip1.SHA256) -OperationId $zipImportOperation
        Check ($zipImport.Status -ceq 'Succeeded' -and $zipImport.Valid -and $zipImport.ProductionVerified -eq $false -and $zipImport.AuthoritativeApproval -eq $false) 'Control: the genuine first package did not import through the formal Target ZIP importer as a non-authoritative read-only import.'
        foreach($readOnly in @(@{Label='directory import result';Value=$import1},@{Label='ZIP import result';Value=$zipImport})){
            Assert-NoProductionClaim $readOnly.Value ('CLI '+$readOnly.Label)
            # HTML 投影：封閉欄位轉換與結果投影（文字主控台寫入作業紀錄的 outputs 也走同一個投影）。
            $closed=ConvertTo-WsmWizardHtmlValue $readOnly.Value
            Assert-NoProductionClaim $closed ('HTML closed projection of the '+$readOnly.Label)
            foreach($projected in @(Get-WsmHtmlResultProjection @($readOnly.Value))){Assert-NoProductionClaim $projected ('HTML result projection of the '+$readOnly.Label)}
            # 投影不得憑空加上 ProductionExecutionEnabled，也不得把它當成可通過的欄位（即使來源物件帶了 true）。
            $hostile=[pscustomobject]@{};foreach($property in $readOnly.Value.PSObject.Properties){$hostile|Add-Member NoteProperty $property.Name $property.Value -Force};$hostile|Add-Member NoteProperty ProductionExecutionEnabled $true -Force
            Check (-not (@((ConvertTo-WsmWizardHtmlValue $hostile).PSObject.Properties.Name) -contains 'ProductionExecutionEnabled')) ('The closed HTML projection passed a ProductionExecutionEnabled field through for the '+$readOnly.Label+'.')
            foreach($projected in @(Get-WsmHtmlResultProjection @($hostile))){Check (-not (@($projected.PSObject.Properties.Name) -contains 'ProductionExecutionEnabled')) ('The HTML result projection passed a ProductionExecutionEnabled field through for the '+$readOnly.Label+'.')}
        }

        # ======================================================================== 16.6-10 續作：耐久作業紀錄解析（路徑不變、內容被換）
        function New-ImportJob($Import,[string]$Action='ImportPackageZip'){[pscustomobject]@{status='Succeeded';action=$Action;role='Target';pairId=$pair;workspace=$Work;jobId=[Guid]::NewGuid().ToString('D');CompletedUtc=(Get-WsmUtc);outputs=@($Import)}}
        $job1=New-ImportJob $zipImport
        $context=Assert-WsmWizardTargetRole $Work $pair
        $resolved=Get-WsmWizardTargetPackage $Work $pair $context @($job1)
        Check ($resolved.ManifestHash -ceq $p1.ManifestHash -and [int]$resolved.Package.Manifest.Generation -eq 1) 'Control: the durable job did not resolve to the first package.'
        $importedDirectory=[IO.Path]::GetDirectoryName([string]$zipImport.ManifestPath);$importedBackup=Join-Path $Root 'imported-original';Copy-TreeOver $importedDirectory $importedBackup
        function Restore-Imported(){Restore-Tree $importedBackup $importedDirectory}
        # (a) manifest.json 被換成另一包（不同 PackageId 與 Generation）的 manifest。
        [IO.File]::Copy($p2.ManifestPath,[string]$zipImport.ManifestPath,$true)
        RejectLike {Get-WsmWizardTargetPackage $Work $pair $context @($job1)} '*changed manifest bytes*' 'Resume resolved a durable job whose manifest path now holds a different package manifest.'
        Restore-Imported
        # (b) manifest 沒動，artifacts.jsonl 被換成另一包的。
        [IO.File]::Copy((Join-Path $p2.Root 'artifacts.jsonl'),(Join-Path $importedDirectory 'artifacts.jsonl'),$true)
        RejectLike {Get-WsmWizardTargetPackage $Work $pair $context @($job1)} '*malformed or changed package material*' 'Resume resolved a durable job whose artifact index was replaced by another package index.'
        Restore-Imported
        # (c) manifest 與索引都沒動，plan.json 被換掉。
        [IO.File]::WriteAllText((Join-Path $importedDirectory 'plan.json'),'{"replaced":"another package plan"}')
        RejectLike {Get-WsmWizardTargetPackage $Work $pair $context @($job1)} '*malformed or changed package material*' 'Resume resolved a durable job whose sealed plan copy was replaced.'
        Restore-Imported
        Check ((Get-WsmWizardTargetPackage $Work $pair $context @($job1)).ManifestHash -ceq $p1.ManifestHash) 'Control: restoring the original bytes did not make the durable job resolvable again.'
        # (d) 另一個同 Generation、不同 PackageId 的封裝也有成功的耐久紀錄：不挑一個猜，關閉式失敗。
        $job1b=New-ImportJob ([pscustomobject]@{Valid=$true;ManifestPath=$p1b.ManifestPath;SHA256=$p1b.ManifestHash;AttemptId=[Guid]::NewGuid().ToString('D')})
        RejectLike {Get-WsmWizardTargetPackage $Work $pair $context @($job1,$job1b)} '*More than one distinct successful package manifest*' 'Resume picked one of two different packages that claim the same generation.'
        # (e) 較新 Generation 的另一包有成功紀錄：以它為準，不回頭使用較舊那包。
        $job2=New-ImportJob ([pscustomobject]@{Valid=$true;ManifestPath=$p2.ManifestPath;SHA256=$p2.ManifestHash;AttemptId=[Guid]::NewGuid().ToString('D')})
        $newer=Get-WsmWizardTargetPackage $Work $pair $context @($job1,$job2)
        Check ($newer.ManifestHash -ceq $p2.ManifestHash -and [int]$newer.Package.Manifest.Generation -eq 2) 'Resume did not follow the newest sealed generation.'

        Write-Output ('PASS: '+$script:checks+' import identity counterexamples (a different package at the same delivery/transport/manifest path is refused at directory import, ZIP import and durable-job resume; read-only imports and their CLI/HTML projections never claim production execution).')
    } $root $work
} finally {
    $fullRoot=[IO.Path]::GetFullPath($root);$tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $fullRoot.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($fullRoot) -notmatch '^wsm-n5-import-'){throw 'Unsafe import identity test cleanup path (fixture root).'}
    $fullWork=[IO.Path]::GetFullPath($work);$publicPrefix='C:\Users\Public\'
    if(-not $fullWork.StartsWith($publicPrefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetDirectoryName($fullWork).TrimEnd('\') -ine 'C:\Users\Public' -or [IO.Path]::GetFileName($fullWork) -notmatch '^d[0-9a-f]{6}$'){throw 'Unsafe import identity test cleanup path (Target work root).'}
    if([IO.Directory]::Exists($fullWork)){if(([IO.File]::GetAttributes($fullWork) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Refusing recursive cleanup of a reparse point.'};Remove-Item -LiteralPath $fullWork -Recurse -Force}
    if([IO.Directory]::Exists($fullRoot)){Remove-Item -LiteralPath $fullRoot -Recurse -Force}
}
