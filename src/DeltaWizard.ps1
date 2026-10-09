function Read-WsmDeltaPackageIdentity {
    $manifest=Read-WsmWizardValue 'MigrationPackage manifest.json 路徑'
    $manifestHash=Read-WsmWizardValue '獨立可信 manifest SHA256'
    $plan=Read-WsmWizardValue '核准 MigrationPlan JSON 路徑'
    $planHash=Read-WsmWizardValue '獨立可信 MigrationPlan SHA256'
    [pscustomobject]@{ManifestPath=$manifest;ManifestHash=$manifestHash;PlanPath=$plan;PlanHash=$planHash}
}

function Read-WsmDeltaInputs {
    $base=Read-WsmDeltaPackageIdentity
    $current=Read-WsmDeltaPackageIdentity
    [pscustomobject]@{Base=$base;Current=$current}
}

function Get-WsmDeltaInputArguments($Inputs) {
    @{
        BaseManifestPath=$Inputs.Base.ManifestPath;BaseManifestHash=$Inputs.Base.ManifestHash
        BasePlanPath=$Inputs.Base.PlanPath;BasePlanHash=$Inputs.Base.PlanHash
        CurrentManifestPath=$Inputs.Current.ManifestPath;CurrentManifestHash=$Inputs.Current.ManifestHash
        CurrentPlanPath=$Inputs.Current.PlanPath;CurrentPlanHash=$Inputs.Current.PlanHash
    }
}

function Get-WsmDeltaWizardCurrentIdentity($Current) {
    $manifest=Read-WsmTrustedJson $Current.ManifestPath $Current.ManifestHash
    $plan=Read-WsmTrustedJson $Current.PlanPath $Current.PlanHash
    Assert-WsmEnvelope $manifest 'MigrationPackage';Assert-WsmEnvelope $plan 'MigrationPlan'
    Assert-WsmDeltaPlanBinding $plan $Current.PlanHash $manifest
    if($plan.ToolFingerprint -cne (Get-WsmToolFingerprint) -or $plan.Mode -cne 'IsolatedPilot') {throw 'Delta cancellation requires the approved current isolated-pilot plan.'}
    [pscustomobject]@{PairId=[string]$manifest.PairId;PlanHash=([string]$Current.PlanHash).ToLowerInvariant();CurrentManifestHash=([string]$Current.ManifestHash).ToLowerInvariant()}
}

function Read-WsmDeltaWizardArchiveIdentity([string]$Path,[string]$ExpectedHash) {
    Assert-WsmNoReparse $Path
    if($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$' -or (Get-WsmDeltaFileHash $Path) -ine $ExpectedHash){throw 'Delta archive does not match its independently trusted SHA256.'}
    if([IO.Path]::GetExtension($Path) -ieq '.json'){$transport=Read-WsmJson $Path;if($transport.Kind -cnotin @('ArtifactDeltaVolumeTransport','ArtifactDeltaDirectoryTransport') -or $transport.FormatVersion -ne 1){throw 'Expected a versioned delta-volume or delta-directory transport index.'};return [pscustomobject]@{PairId=[string]$transport.PairId;PlanHash=([string]$transport.PlanHash).ToLowerInvariant();CurrentManifestHash=([string]$transport.CurrentManifestHash).ToLowerInvariant();TransportRecordHash=$ExpectedHash.ToLowerInvariant();TransportKind=[string]$transport.Kind}}
    $stream=[IO.File]::Open([IO.Path]::GetFullPath($Path),'Open','Read','Read');$archive=$null
    try{
        Add-Type -AssemblyName System.IO.Compression
        $archive=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Read,$true)
        $entries=@($archive.Entries | Where-Object FullName -CEQ 'transport.json')
        if($entries.Count -ne 1 -or $entries[0].Length -lt 1 -or $entries[0].Length -gt 1MB){throw 'Delta ZIP must contain exactly one bounded transport.json record.'}
        $input=$entries[0].Open();$memory=New-Object IO.MemoryStream
        try{$buffer=New-Object byte[] 65536;while(($read=$input.Read($buffer,0,$buffer.Length)) -gt 0){if($memory.Length+$read -gt 1MB){throw 'Delta transport record exceeds its 1 MiB limit.'};$memory.Write($buffer,0,$read)};if($memory.Length -ne $entries[0].Length){throw 'Delta transport record actual size mismatch.'};$bytes=$memory.ToArray()}finally{$input.Dispose();$memory.Dispose()}
        $transport=ConvertFrom-WsmJson ([Text.Encoding]::UTF8.GetString($bytes));Assert-WsmEnvelope $transport 'ArtifactDeltaTransport';Assert-WsmId $transport.PairId
        foreach($field in @('PlanHash','BaseManifestHash','CurrentManifestHash','SummaryHash','ChangesHash')){if([string]$transport.$field -notmatch '^[a-fA-F0-9]{64}$'){throw ('Delta transport has an invalid '+$field+'.')}}
        if($transport.Mode -cne 'IsolatedPilot'){throw 'Delta transport is not an isolated-pilot package.'}
        $sha=[Security.Cryptography.SHA256]::Create();try{$transportRecordHash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        [pscustomobject]@{PairId=[string]$transport.PairId;PlanHash=([string]$transport.PlanHash).ToLowerInvariant();CurrentManifestHash=([string]$transport.CurrentManifestHash).ToLowerInvariant();TransportRecordHash=$transportRecordHash;TransportKind=[string]$transport.Kind}
    }finally{if($archive){$archive.Dispose()};$stream.Dispose()}
}

function Read-WsmDeltaWizardImportedIdentity([string]$TransportPath,[string]$ExpectedHash,[string]$ImportedDirectory) {
    $archiveIdentity=Read-WsmDeltaWizardArchiveIdentity $TransportPath $ExpectedHash
    Assert-WsmNoReparse $ImportedDirectory
    $recordPath=Join-Path ([IO.Path]::GetFullPath($ImportedDirectory)) 'transport.json';Assert-WsmNoReparse $recordPath
    if(-not [IO.File]::Exists($recordPath)){throw 'Imported delta transport.json is missing.'}
    $file=New-Object IO.FileInfo($recordPath);if($file.Length -lt 1 -or $file.Length -gt 1MB){throw 'Imported delta transport.json exceeds its 1 MiB limit.'}
    $bytes=[IO.File]::ReadAllBytes($recordPath);$sha=[Security.Cryptography.SHA256]::Create()
    try{$recordHash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    if($recordHash -ine $archiveIdentity.TransportRecordHash){throw 'Imported transport.json differs from the trusted delta archive record.'}
    $transport=ConvertFrom-WsmJson ([Text.Encoding]::UTF8.GetString($bytes));if($transport.Kind -cin @('ArtifactDeltaVolumeTransport','ArtifactDeltaDirectoryTransport')){if($transport.FormatVersion -ne 1){throw 'Unsupported delta-volume format.'}}else{Assert-WsmEnvelope $transport 'ArtifactDeltaTransport'}
    if($transport.PairId -cne $archiveIdentity.PairId -or $transport.PlanHash -ine $archiveIdentity.PlanHash -or $transport.CurrentManifestHash -ine $archiveIdentity.CurrentManifestHash){throw 'Imported delta identity differs from the trusted transport archive.'}
    $archiveIdentity
}

function New-WsmDeltaWizardToken($Identity,[string]$StateDirectory) {
    New-WsmWizardCancellation $Identity.PairId $Identity.PlanHash $Identity.CurrentManifestHash ([IO.Path]::GetFullPath($StateDirectory))
}

function Resolve-WsmDeltaWizardAttempt($Identity,[string]$Role,[ValidateSet('Zip','Directory')][string]$ExpectedMode) {
    if(-not (Get-Command Resolve-WsmOutputWorkspace -ErrorAction SilentlyContinue)){throw 'OutputWorkspace profile support is not loaded; delta delivery is blocked.'}
    $workRoot=Read-WsmWizardValue '本機受控 WorkRoot（已初始化OutputProfile）';$attemptId=Read-WsmWizardValue '此輸出嘗試的AttemptId（留空建立新嘗試）'
    $workspace=Resolve-WsmOutputWorkspace -WorkRoot $workRoot -Role $Role -PairId $Identity.PairId -PlanHash $Identity.PlanHash -AttemptId $attemptId
    if($workspace.AttemptProfile.Mode -cne $ExpectedMode){throw ('OutputProfile mode is '+$workspace.AttemptProfile.Mode+'; select the matching delta delivery action, no transport fallback is allowed.')}
    if($Role -ceq 'Target' -and (($ExpectedMode -ceq 'Zip' -and $Identity.TransportKind -cne 'ArtifactDeltaVolumeTransport') -or ($ExpectedMode -ceq 'Directory' -and $Identity.TransportKind -cne 'ArtifactDeltaDirectoryTransport'))){throw 'Delta transport kind differs from the enrolled OutputProfile; no legacy ZIP or mode fallback is permitted.'}
    $workspace
}
function Resolve-WsmDeltaWizardTargetWorkspace($Identity) {
    $workRoot=Read-WsmWizardValue '目標固定 WorkRoot（使用已登記的配對狀態與匯入目錄）'
    $workspace=Resolve-WsmOutputWorkspace -WorkRoot $workRoot -Role Target -PairId $Identity.PairId -PlanHash $Identity.PlanHash
    if(($workspace.Profile.Mode -ceq 'Zip' -and $Identity.TransportKind -cne 'ArtifactDeltaVolumeTransport') -or ($workspace.Profile.Mode -ceq 'Directory' -and $Identity.TransportKind -cne 'ArtifactDeltaDirectoryTransport')){throw 'Delta transport kind differs from the enrolled OutputProfile; no legacy ZIP or mode fallback is permitted.'}
    [pscustomobject]@{WorkRoot=$workRoot;Workspace=$workspace}
}
function Assert-WsmDeltaWizardImportedWorkspace([string]$ImportedDirectory,[string]$WorkRoot,[string]$PairId) {
    $path=[IO.Path]::GetFullPath($ImportedDirectory);$pairRoot=[IO.Path]::GetFullPath((Join-Path $WorkRoot ('pairs\'+$PairId))).TrimEnd('\')
    Assert-WsmNoReparse $path
    $pattern='^'+[regex]::Escape($pairRoot+'\attempts\')+'[^\\]+\\packages(?:\\|$)'
    if($path -notmatch $pattern){throw 'Imported delta material is outside this enrolled pair AttemptId packages directory.'}
}

function Read-WsmDeltaWizardGeneralHostEvidence([string]$ImportedDirectory) {
    $transport=Read-WsmJson (Join-Path $ImportedDirectory 'transport.json');$manifest=Read-WsmTrustedJson (Join-Path $ImportedDirectory 'current\manifest.json') $transport.CurrentManifestHash;$plan=Read-WsmTrustedJson (Join-Path $ImportedDirectory 'current\plan.json') $transport.PlanHash
    if($plan.SchemaVersion -ne 2 -or $plan.ScopeMode -cne 'GeneralHost'){return @()}
    $value=Read-WsmWizardValue '核准且可信的GeneralHost evidence引用，格式為路徑|SHA256；多筆用分號分隔'
    $refs=New-Object 'System.Collections.Generic.List[object]';foreach($part in $value.Split(';')){$fields=$part.Split('|');if($fields.Count -ne 2 -or [string]::IsNullOrWhiteSpace($fields[0]) -or $fields[1] -notmatch '^[a-fA-F0-9]{64}$'){throw 'GeneralHost evidence reference must contain one path and one SHA256.'};$refs.Add([pscustomobject]@{Path=[IO.Path]::GetFullPath($fields[0].Trim());SHA256=$fields[1].ToLowerInvariant()})};$refs.ToArray()
}

function Show-WsmDeltaWizard {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Source','Target')][string]$Role)

    while($true){
        if($Role -ceq 'Source'){
            Write-Host "`n來源本機增量搬移（離線操作；目標已擁有的 FileScope baseline 會先核對並保留回復目錄）"
            Write-Host '1 建立 initial/final 差異清單  2 驗證差異清單  3 匯出舊版單一 ZIP  4 匯出受限分卷 ZIP  5 匯出乾淨delta目錄  0 返回'
        }else{
            Write-Host "`n目標本機增量套用（先預覽；核對 baseline 後以同目錄備份保留舊內容）"
            Write-Host '1 舊版單 ZIP 進階 API 入口  2 預覽並套用  3 預覽並修復中斷交易  4 匯入受限分卷 delta  5 匯入delta目錄  0 返回'
        }
        try{$choice=Read-WsmWizardValue '操作'}catch [OperationCanceledException]{return}
        try{
            if($Role -ceq 'Source'){
                switch($choice){
                    '1' {
                        $inputs=Read-WsmDeltaInputs;$args=Get-WsmDeltaInputArguments $inputs
                        $args.OutputPath=Read-WsmWizardValue 'changes.jsonl 新輸出路徑'
                        $args.SummaryPath=Read-WsmWizardValue 'summary.json 新輸出路徑'
                        $ids=Read-WsmWizardValue '已核准且目標工具擁有的 FileScope ItemId，以逗號分隔'
                        $args.OwnedItemIds=@($ids.Split(',') | ForEach-Object {$_.Trim()} | Where-Object {$_})
                        $result=New-WsmArtifactDeltaManifest @args
                        Write-Host ('差異清單：'+$result.ChangesPath+' / SHA256：'+$result.ChangesHash)
                        Write-Host ('差異摘要：'+$result.SummaryPath+' / SHA256：'+$result.SummaryHash)
                        $result | Format-List
                    }
                    '2' {
                        $summary=Read-WsmWizardValue 'ArtifactDelta summary.json 路徑';$summaryHash=Read-WsmWizardValue '獨立可信 summary SHA256'
                        $changes=Read-WsmWizardValue 'changes.jsonl 路徑';$inputs=Read-WsmDeltaInputs;$args=Get-WsmDeltaInputArguments $inputs
                        $args.SummaryPath=$summary;$args.SummaryHash=$summaryHash;$args.ChangesPath=$changes
                        Test-WsmArtifactDeltaManifest @args | Format-List
                    }
                    '3' {
                        $inputs=Read-WsmDeltaInputs;$args=Get-WsmDeltaInputArguments $inputs
                        $args.SummaryPath=Read-WsmWizardValue 'ArtifactDelta summary.json 路徑';$args.SummaryHash=Read-WsmWizardValue '獨立可信 summary SHA256'
                        $args.ChangesPath=Read-WsmWizardValue 'changes.jsonl 路徑';$args.OutputPath=Read-WsmWizardValue '增量 ZIP 新輸出路徑'
                        $identity=Get-WsmDeltaWizardCurrentIdentity $inputs.Current
                        $zipPath=[IO.Path]::GetFullPath($args.OutputPath);$outputRoot=[IO.Path]::GetDirectoryName($zipPath)
                        $token=New-WsmDeltaWizardToken $identity $outputRoot;$args.OutputPath=$zipPath;$args.CancellationToken=$token
                        Export-WsmArtifactDeltaZip @args | Format-List
                    }
                    '4' {
                        $inputs=Read-WsmDeltaInputs;$args=Get-WsmDeltaInputArguments $inputs
                        $args.SummaryPath=Read-WsmWizardValue 'ArtifactDelta summary.json 路徑';$args.SummaryHash=Read-WsmWizardValue '獨立可信 summary SHA256'
                        $args.ChangesPath=Read-WsmWizardValue 'changes.jsonl 路徑';$identity=Get-WsmDeltaWizardCurrentIdentity $inputs.Current;$workspace=Resolve-WsmDeltaWizardAttempt $identity 'Source' 'Zip';$args.OutputDirectory=$workspace.TransportDirectory;$args.ScratchDirectory=$workspace.ScratchDirectory;$args.VolumeBytes=[long]$workspace.AttemptProfile.VolumeBytes;$token=New-WsmDeltaWizardToken $identity $args.OutputDirectory;$args.CancellationToken=$token
                        $result=Export-WsmArtifactDeltaVolumes @args;$result | Format-List
                        Export-WsmDeliveryDocument -TransportPath $result.TransportPath -ExpectedHash $result.SHA256 -ManifestPath $inputs.Current.ManifestPath -ExpectedManifestHash $inputs.Current.ManifestHash -BaseManifestPath $inputs.Base.ManifestPath -BaseManifestHash $inputs.Base.ManifestHash -OperationKind Delta -SummaryPath $args.SummaryPath -SummaryHash $args.SummaryHash -ChangesPath $args.ChangesPath -OutputDirectory (Join-Path $workspace.ReportsDirectory ('delivery-'+[Guid]::NewGuid().ToString('N'))) | Format-List
                    }
                    '5' {
                        $inputs=Read-WsmDeltaInputs;$args=Get-WsmDeltaInputArguments $inputs
                        $args.SummaryPath=Read-WsmWizardValue 'ArtifactDelta summary.json 路徑';$args.SummaryHash=Read-WsmWizardValue '獨立可信 summary SHA256'
                        $args.ChangesPath=Read-WsmWizardValue 'changes.jsonl 路徑';$identity=Get-WsmDeltaWizardCurrentIdentity $inputs.Current;$workspace=Resolve-WsmDeltaWizardAttempt $identity 'Source' 'Directory';$args.OutputDirectory=Join-Path $workspace.TransportDirectory ('delta-directory-'+$workspace.AttemptId);$args.ScratchDirectory=$workspace.ScratchDirectory;$token=New-WsmDeltaWizardToken $identity $args.OutputDirectory;$args.CancellationToken=$token
                        $result=Export-WsmArtifactDeltaDirectory @args;$result | Format-List
                        Export-WsmDeliveryDocument -TransportPath $result.TransportPath -ExpectedHash $result.SHA256 -ManifestPath $inputs.Current.ManifestPath -ExpectedManifestHash $inputs.Current.ManifestHash -BaseManifestPath $inputs.Base.ManifestPath -BaseManifestHash $inputs.Base.ManifestHash -OperationKind Delta -OutputDirectory (Join-Path $workspace.ReportsDirectory ('delivery-'+[Guid]::NewGuid().ToString('N'))) | Format-List
                    }
                    default {Write-Host '無效選項；未修改。'}
                }
            }else{
                switch($choice){
                    '1' {Write-Host '舊版單 ZIP 不符合新版 OutputProfile；請以進階操作請求 DeltaImport 使用既有 API，不能當成分卷／Directory 匯入。';Show-WsmOperationMenu;continue}
                    {$_ -in @('4','5')} {
                        $isVolume=($choice -ceq '4');$isDirectory=($choice -ceq '5');$transport=Read-WsmWizardValue $(if($isVolume){'增量分卷transport JSON路徑'}elseif($isDirectory){'增量目錄中的transport.json路徑'}else{'增量 transport ZIP 路徑'});$hash=Read-WsmWizardValue '獨立可信 transport SHA256';$output='';$scratch=''
                        $identity=Read-WsmDeltaWizardArchiveIdentity $transport $hash
                        $expectedMode=if($isDirectory){'Directory'}else{'Zip'};$workspace=Resolve-WsmDeltaWizardAttempt $identity 'Target' $expectedMode;$output=Join-Path $workspace.PackagesDirectory ('delta-import-'+$workspace.AttemptId);$scratch=$workspace.ScratchDirectory;$token=New-WsmDeltaWizardToken $identity $output;$result=Import-WsmArtifactDeltaByProfile -OutputProfile $workspace.AttemptProfile -TransportPath $transport -ExpectedHash $hash -OutputDirectory $output -ScratchDirectory $scratch -CancellationToken $token
                        Export-WsmImportedDeliveryReceipt -TransportPath $transport -ExpectedHash $hash -ManifestPath (Join-Path $result.Directory 'current\manifest.json') -ExpectedManifestHash $result.CurrentManifestHash -BaseManifestPath (Join-Path $result.Directory 'base\manifest.json') -BaseManifestHash $result.BaseManifestHash -OperationKind Delta -ImportedDirectory $result.Directory -OutputDirectory (Join-Path $workspace.ReportsDirectory ('import-'+[Guid]::NewGuid().ToString('N'))) | Format-List
                        Write-Host ('已驗證匯入目錄：'+$result.Directory)
                        Write-Host ('基底 manifest SHA256：'+$result.BaseManifestHash+'；目前 manifest SHA256：'+$result.CurrentManifestHash+'；generation：'+$result.Generation)
                        $result | Format-List
                    }
                    {$_ -in @('2','3')} {
                        $transport=Read-WsmWizardValue '受限分卷／Directory 增量 transport.json（舊版 ZIP 請使用進階 API）';$hash=Read-WsmWizardValue '獨立可信 transport SHA256';$identity=Read-WsmDeltaWizardArchiveIdentity $transport $hash;$targetContext=Resolve-WsmDeltaWizardTargetWorkspace $identity
                        $imported=Read-WsmWizardValue '此 pair AttemptId/packages 下已驗證的增量匯入目錄';Assert-WsmDeltaWizardImportedWorkspace $imported $targetContext.WorkRoot $identity.PairId;$state=$targetContext.Workspace.StateDirectory;$generalEvidence=Read-WsmDeltaWizardGeneralHostEvidence $imported
                        $preview=Invoke-WsmArtifactDeltaRestore -TransportPath $transport -ExpectedTransportHash $hash -ImportedDirectory $imported -TargetStateDirectory $state -GeneralHostEvidence $generalEvidence -WhatIf
                        Write-Host '預覽完成。套用時會檢查已擁有的 baseline hash；每個舊 scope 會保留在 transaction 列出的 sibling backup 目錄，請勿手動刪除。'
                        $preview | Format-List
                        $action=if($choice -ceq '2'){'套用'}else{'修復／接續'}
                        $ack=if($choice -ceq '2'){'APPLY-DELTA '+$preview.PairId}else{'REPAIR-DELTA '+$preview.PairId}
                        if((Read-WsmWizardValue ('確認'+$action+'，輸入 '+$ack)) -cne $ack){Write-Host '未確認；未修改。';continue}
                        $identity=Read-WsmDeltaWizardImportedIdentity $transport $hash $imported
                        if($identity.PairId -cne $preview.PairId){throw 'Preview pair differs from the trusted delta transport identity.'}
                        $token=New-WsmDeltaWizardToken $identity $state
                        if($choice -ceq '2'){$result=Invoke-WsmArtifactDeltaRestore -TransportPath $transport -ExpectedTransportHash $hash -ImportedDirectory $imported -TargetStateDirectory $state -GeneralHostEvidence $generalEvidence -CancellationToken $token -Confirm:$false}
                        else{$result=Repair-WsmArtifactDeltaRestore -TransportPath $transport -ExpectedTransportHash $hash -ImportedDirectory $imported -TargetStateDirectory $state -GeneralHostEvidence $generalEvidence -CancellationToken $token}
                        if($result.PSObject.Properties['TransactionPath'] -and $result.TransactionPath -and [IO.File]::Exists($result.TransactionPath)){
                            $transaction=Read-WsmJson $result.TransactionPath
                            $backupPaths=@($transaction.Operations | ForEach-Object {$_.Backup} | Where-Object {$_})
                            Write-Host 'baseline／回復目錄（保留至明確清理）：'
                            if($backupPaths.Count){Write-Host ($backupPaths -join "`n")}
                        }
                        Write-Host ('Materialized manifest（供既有 package 驗證／切換流程）：'+$result.DeltaPackageManifestPath+' / SHA256：'+$result.DeltaPackageManifestHash)
                        $result | Format-List
                    }
                    default {Write-Host '無效選項；未修改。'}
                }
            }
        }catch [OperationCanceledException]{Write-Host $_.Exception.Message}catch [IO.EndOfStreamException]{throw}catch{Write-Host ('增量操作失敗：'+$_.Exception.Message) -ForegroundColor Red;Get-WsmFailureDetails $_ | Format-List Category,NativeCode,Hint}
    }
}
