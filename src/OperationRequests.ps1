function Get-WsmOperationActions {
    [ordered]@{SpecBundleExport='Export-WsmMigrationSpecBundle';SpecBundlePreview='Get-WsmMigrationSpecBundlePreview';SpecBundleImport='Import-WsmMigrationSpecBundle';RepairWorkspace='Repair-WsmWorkspace';RawEvidence='Export-WsmRawEvidenceManifest';RegisterTarget='Register-WsmTarget';ToolRelease='Export-WsmToolRelease';SourceResult='Export-WsmSourceStageResult';IdentityMap='Set-WsmIdentityMap';ConfigureMigration='Set-WsmMigrationSpec';ApproveMigration='Approve-WsmMigrationPlan';EstimatePackage='Get-WsmPackageEstimate';ExportPackage='Export-WsmMigrationPackage';CheckPackage='Test-WsmMigrationPackage';RestorePreview='Get-WsmRestorePreview';Restore='Invoke-WsmRestore';FreezeSource='Export-WsmFreezeRecord';ValidationEvidence='Set-WsmValidationEvidence';Validate='Invoke-WsmValidation';CutoverPlan='New-WsmCutoverPlan';Cutover='Invoke-WsmCutover';Acceptance='Get-WsmAcceptanceGates';ExportResult='Export-WsmStageResult';Repair='Repair-WsmOperation';RollbackPreview='Get-WsmRollbackPreview';Rollback='Invoke-WsmRollback';CheckJournal='Test-WsmJournal';PackageZip='Export-WsmPackageZip';ImportPackageZip='Import-WsmPackageZip';MigrationReport='Export-WsmOperationReport'}
}
function Invoke-WsmOperationRequest {
    [CmdletBinding(SupportsShouldProcess)]param([string]$Path,[string]$ExpectedHash,[hashtable]$Secrets=@{})
    $request=Read-WsmTrustedJson $Path $ExpectedHash;Assert-WsmEnvelope $request 'OperationRequest';Assert-WsmFields $request @('SchemaVersion','ToolVersion','Kind','Action','Arguments') @('SchemaVersion','ToolVersion','Kind','Action','Arguments')
    $actions=Get-WsmOperationActions;if(-not $actions.Contains($request.Action)){throw (New-WsmContractError 'Unknown operation request action.')};$command=Get-Command $actions[$request.Action] -CommandType Function
    $arguments=@{};foreach($p in $request.Arguments.PSObject.Properties){if(-not $command.Parameters.ContainsKey($p.Name) -or $p.Name -in @('Secrets','Verbose','Debug','ErrorAction','ErrorVariable','OutVariable','OutBuffer','PipelineVariable','InformationAction','InformationVariable','WarningAction','WarningVariable','Confirm','WhatIf')){throw (New-WsmContractError ('Unsupported request parameter: '+$p.Name))};$value=$p.Value;if($p.Name -eq 'SidMap'){$value=@{};foreach($entry in $p.Value.PSObject.Properties){$value[$entry.Name]=[string]$entry.Value}};$arguments[$p.Name]=$value}
    if($command.Parameters.ContainsKey('Secrets')){$arguments.Secrets=$Secrets}
    foreach($parameter in $command.Parameters.Values){$mandatory=@($parameter.Attributes | Where-Object {$_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory}).Count -gt 0;if($mandatory -and (-not $arguments.ContainsKey($parameter.Name) -or $null -eq $arguments[$parameter.Name])){throw (New-WsmContractError ('Required request parameter missing; noninteractive prompts prohibited: '+$parameter.Name))}}
    if($WhatIfPreference -and $command.Parameters.ContainsKey('WhatIf')){$arguments.WhatIf=$true}
    # Only this locally installed allowlist is executable. Requests contain typed data, never commands.
    & $command @arguments
}
function Get-WsmOperationStatusCode($Result) {
    foreach($r in @($Result)){if($r.PSObject.Properties['Blocked'] -and $r.Blocked){return 2};if($r.PSObject.Properties['Passed'] -and -not $r.Passed){return 2};if($r.PSObject.Properties['Stage'] -and $r.Stage -in @('Failed','Blocked','ManualEvidenceRequired','RebootRequired','PostCutoverValidationRequired')){if($r.Stage -eq 'Failed'){return 1};return 2};if($r.PSObject.Properties['FinalAccepted'] -and (-not $r.FinalAccepted -or -not $r.RetirementReady)){return 2}}
    0
}
function Show-WsmMigrationMenu {
    param([string]$Workspace)
    while($true){Write-Host "`n遷移階段（目前為隔離 pilot；真實 Server 資格未驗收）";Write-Host '來源本機：ExportPackage／FreezeSource。目標本機：RegisterTarget／RestorePreview／Restore／Validate／Cutover／Rollback。';Write-Host '管理工作區：ConfigureMigration／ApproveMigration／MigrationReport。所有操作使用相同核心。';Write-Host '1 列出操作與參數  2 預覽已填好的操作請求  3 執行操作請求  0 返回';$choice=Read-Host '選項';if($choice -eq '0'){return}
        try{switch($choice){
            '1' {foreach($entry in (Get-WsmOperationActions).GetEnumerator()){Write-Host ($entry.Key+': '+(@((Get-Command $entry.Value).Parameters.Keys | Where-Object {$_ -notin @('Secrets','Verbose','Debug','ErrorAction','ErrorVariable','OutVariable','OutBuffer','PipelineVariable','InformationAction','InformationVariable','WarningAction','WarningVariable','Confirm','WhatIf')}) -join ', '))}}
            '2' {$path=Read-Host 'OperationRequest JSON 路徑（0 取消）';if($path -eq '0'){continue};$hash=Read-Host '獨立可信 SHA256';$request=Read-WsmTrustedJson $path $hash;Assert-WsmEnvelope $request 'OperationRequest';$request | ConvertTo-Json -Depth 12 | Write-Host;Write-Host '設定預覽請使用 RestorePreview／RollbackPreview／CutoverPlan；畫面不讀取或顯示密碼。'}
            '3' {$path=Read-Host 'OperationRequest JSON 路徑（0 取消）';if($path -eq '0'){continue};$hash=Read-Host '獨立可信 SHA256';$request=Read-WsmTrustedJson $path $hash;Assert-WsmEnvelope $request 'OperationRequest';Write-Host ('操作：'+$request.Action);$request.Arguments | Format-List;$secretRefs=Read-Host '需要的 SecretRef，以逗號分隔（可留空；密碼僅記憶體）';$secrets=@{};try{foreach($name in $secretRefs.Split(',')){if($name.Trim()){$credential=Get-Credential -Message ('SecretRef '+$name.Trim());if(-not $credential){throw 'Credential entry cancelled.'};$secrets[$name.Trim()]=$credential}};Invoke-WsmOperationRequest $path $hash $secrets | Format-List}finally{$secrets.Clear();$credential=$null}}
            default {Write-Host '無效選項；未修改。'}
        }}catch{Write-Host ('操作失敗：'+$_.Exception.Message) -ForegroundColor Red}
    }
}
