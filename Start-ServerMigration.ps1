#requires -Version 5.1
[CmdletBinding()] param(
    [string]$Action='Menu',[switch]$DeepDiscovery,
    [string]$Workspace,[string]$Path,[string]$ExpectedHash,[string]$TargetName,[string]$PairId,
    [string]$Category,[string]$Search,[string]$Decision='Pending',[string]$Reason,[int]$ExpectedRevision=-1,[string]$ItemId,[string]$Name,[string]$NaturalKey,[string]$Owner,[string]$Evidence,[string]$Mapping,[ValidateSet('Path','Account','Endpoint')][string]$MappingType='Path')
$ErrorActionPreference='Stop'
if (-not $Workspace) { $Workspace=Join-Path $PSScriptRoot 'migration-workspace' }
Import-Module (Join-Path $PSScriptRoot 'src\WindowsServerMigration.psd1') -Force
function Read-MenuValue([string]$Label) {
    $value=Read-Host ($Label+'（0 取消；literal:0 表示文字 0）')
    if($null -eq $value){throw (New-Object IO.EndOfStreamException('Console input ended.'))}
    if($value -eq '0'){throw (New-Object OperationCanceledException('已取消本步驟，未提交操作。'))}
    if($value -ceq 'literal:0'){return '0'}
    $value
}
function Select-Pair {
    $pairs=@((Get-WsmFleet $Workspace).Pairs)
    if (-not $pairs.Count) { throw '尚未匯入任何主機。' }
    for ($i=0;$i -lt $pairs.Count;$i++) { Write-Host ('{0}. {1} -> {2}' -f ($i+1),$pairs[$i].SourceName,$pairs[$i].TargetName) }
    $choice=0; if (-not [int]::TryParse((Read-MenuValue '選擇主機編號'),[ref]$choice) -or $choice -lt 1 -or $choice -gt $pairs.Count) { throw '無效編號。' }
    $pairs[$choice-1].PairId
}
function Review-Pair([string]$SelectedPair) {
    Get-WsmCategorySummary $Workspace $SelectedPair | Format-Table
    $c=Get-WsmCatalog $Workspace $SelectedPair; $page=1; $pageSize=50; $category=''; $search=''; $decisionFilter='All'; $builtIn='All'; $group=''; $sort='Name'
    if ($c.PSObject.Properties['ReviewView']) { $page=$c.ReviewView.Page; $pageSize=$c.ReviewView.PageSize; $category=$c.ReviewView.Category; $search=$c.ReviewView.Search }
    if ($c.PSObject.Properties['ReviewView'] -and $c.ReviewView.PSObject.Properties['Decision']) { $decisionFilter=$c.ReviewView.Decision; $builtIn=$c.ReviewView.BuiltIn; $group=$c.ReviewView.Group; $sort=$c.ReviewView.Sort }
    Write-Host ('已恢復篩選：類別={0} 搜尋={1}，頁大小={2}。f 可修改。' -f $category,$search,$pageSize)
    while ($true) {
        $view=Get-WsmItems $Workspace $SelectedPair -Category $category -Search $search -Page $page -PageSize $pageSize -Decision $decisionFilter -BuiltIn $builtIn -Group $group -Sort $sort
        Set-WsmReviewView $Workspace $SelectedPair $category $search $page $pageSize -Decision $decisionFilter -BuiltIn $builtIn -Group $group -Sort $sort
        Write-Host ('共 {0} 筆，第 {1} 頁，審核版本 {2}' -f $view.Total,$page,$view.DecisionRevision)
        for ($i=0;$i -lt $view.Items.Count;$i++) { $r=$view.Items[$i]; Write-Host ('{0}. [{1}] [{2}] [{3}] {4}' -f ($i+1),$r.Category,$r.Status,$r.Decision,$r.Name) }
        $command=Read-Host 'n 下一頁 / p 上一頁 / f 篩選及頁大小 / i 納入 / e 排除 / a 全部符合篩選的規則操作 / u 撤銷 / q 返回'
        if($null -eq $command){throw (New-Object IO.EndOfStreamException('Console input ended.'))}
        try { switch ($command) {
            '0' { return }
            'q' { return }
            'n' { if ($page*$pageSize -lt $view.Total) { $page++ } }
            'p' { $page=[math]::Max(1,$page-1) }
            'f' { $nextCategory=Read-MenuValue '類別（留空為全部）'; $nextSearch=Read-MenuValue '搜尋名稱／路徑／帳號／端點／應用組合（留空為全部）'; $size=Read-MenuValue '每頁 20／50／100'; if ($size -notin @('20','50','100')) { throw '頁大小必須為20、50或100。' }; $nextDecision=Read-MenuValue '決定篩選 All／Include／Exclude／Pending'; $nextBuiltIn=Read-MenuValue '內建篩選 All／Unknown／SuggestedInternal／ConfirmedInternal／ConfirmedThirdParty'; $nextGroup=Read-MenuValue '應用組合（留空為全部）'; $nextSort=Read-MenuValue '排序 Name／Category／Kind／Decision／NaturalKey'; if($nextDecision -notin @('All','Include','Exclude','Pending') -or $nextBuiltIn -notin @('All','Unknown','SuggestedInternal','ConfirmedInternal','ConfirmedThirdParty') -or $nextSort -notin @('Name','Category','Kind','Decision','NaturalKey')){throw '無效篩選／排序。'}; $category=$nextCategory;$search=$nextSearch;$pageSize=[int]$size;$decisionFilter=$nextDecision;$builtIn=$nextBuiltIn;$group=$nextGroup;$sort=$nextSort;$page=1 }
            'a' { $decision=Read-MenuValue '全部符合項目的 Include／Exclude／Pending'; $reason=Read-MenuValue '理由'; $preview=Get-WsmRulePreview $Workspace $SelectedPair -Category $category -Search $search -CurrentDecision $decisionFilter -BuiltIn $builtIn -Group $group -Decision $decision -Reason $reason; $preview | Select-Object Selected,Changed,DecisionRevision | Format-List; $preview.Sample | Format-Table; $preview.Conflicts | Format-Table; if ((Read-MenuValue '確認操作的是跨頁全部符合項目，輸入 APPLY') -ceq 'APPLY') { Invoke-WsmReviewRule $Workspace $SelectedPair -Category $category -Search $search -CurrentDecision $decisionFilter -BuiltIn $builtIn -Group $group -Decision $decision -Reason $reason -ExpectedRevision $preview.DecisionRevision | Format-List } }
            'u' { Undo-WsmDecision $Workspace $SelectedPair $view.DecisionRevision | Out-Null }
            { $_ -in @('i','e') } {
                $inputRows=Read-MenuValue '輸入本頁編號，以逗號分隔；all 選取本頁全部（跨頁大量處理請使用 CSV）'
                $ids=@()
                if ($inputRows -eq 'all') { $ids=@($view.Items | ForEach-Object ItemId) }
                else { foreach ($v in $inputRows.Split(',')) { $numbers=@(); if ($v.Trim() -match '^(\d+)-(\d+)$') { $first=[int]$matches[1]; $last=[int]$matches[2]; if ($first -lt 1 -or $last -lt $first -or $last -gt $view.Items.Count) { throw '範圍無效。' }; $numbers=@($first..$last) } else { $number=0; if (-not [int]::TryParse($v.Trim(),[ref]$number)) { throw '編號無效。' }; $numbers=@($number) }; foreach ($number in $numbers) { if ($number -lt 1 -or $number -gt $view.Items.Count) { throw '編號無效。' }; $ids+=$view.Items[$number-1].ItemId } } }
                if (-not $ids.Count) { throw '沒有選取項目。' }
                $decision='Include'; if ($command -eq 'e') { $decision='Exclude' }
                $reason=Read-MenuValue '理由（排除時必填）'
                $preview=Get-WsmDecisionPreview $Workspace $SelectedPair $ids $decision $reason; $preview | Select-Object Selected,Changed | Format-List; $preview.Sample | Format-Table; $preview.Conflicts | Format-Table
                if ((Read-MenuValue '輸入 APPLY 套用') -ceq 'APPLY') { Set-WsmDecision $Workspace $SelectedPair $ids $decision $reason $view.DecisionRevision | Out-Null }
            }
        }} catch [OperationCanceledException] { Write-Host $_.Exception.Message } catch [IO.EndOfStreamException] { throw } catch { Write-Host ('操作失敗：'+$_.Exception.Message) -ForegroundColor Red;Get-WsmFailureDetails $_ | Format-List Category,NativeCode,Hint }
    }
}
try {
    if ($Action -eq 'Operation') { $result=Invoke-WsmOperationRequest $Path $ExpectedHash; $result; exit (Get-WsmOperationStatusCode $result) }
    if ($Action -cnotin @('Menu','Inventory','Initialize','Import','ImportZip','Report','FleetReport','ExportCsv','ImportCsv','Issues','RulePreview','ApplyRule','ManualItem','Mapping','Evidence','Approve','FleetGraph','ImportResult','Capabilities','ConsistencyGroup','TemplatePreview','ApplyTemplate','ExportTemplate')) { throw (New-Object IO.InvalidDataException('Unknown action.')) }
    if ($Action -ne 'Menu') {
        if ($Action -in @('Inventory','Import','ImportZip','Report','FleetReport','ExportCsv','ImportCsv','Approve','FleetGraph','ImportResult') -and [string]::IsNullOrWhiteSpace($Path)) { throw (New-Object IO.InvalidDataException('This action requires -Path.')) }
        if ($Action -in @('Import','ImportZip','ImportResult') -and $ExpectedHash -notmatch '^[a-fA-F0-9]{64}$') { throw (New-Object IO.InvalidDataException('This action requires an independently obtained -ExpectedHash.')) }
        if ($Action -in @('ApplyRule','ManualItem','Mapping','Evidence','Approve','ConsistencyGroup','ApplyTemplate') -and $ExpectedRevision -lt 0) { throw (New-Object IO.InvalidDataException('This action requires -ExpectedRevision from the current catalog/preview.')) }
        switch ($Action) {
            Inventory { $result=Export-WsmInventory -OutputDirectory $Path -DeepDiscovery:$DeepDiscovery; $result; if ($result.Incomplete -gt 0) { exit 2 } }
            Initialize { Initialize-WsmWorkspace $Workspace }
            Import { Import-WsmInventory $Workspace $Path $ExpectedHash $TargetName }
            ImportZip { Import-WsmInventoryArchive $Workspace $Path $ExpectedHash $TargetName }
            Report { Export-WsmReport $Workspace $PairId $Path }
            FleetReport { Export-WsmFleetReport $Workspace $Path }
            ExportCsv { Export-WsmDecisions $Workspace $PairId $Path }
            ImportCsv { Import-WsmDecisions $Workspace $PairId $Path }
            Issues { $issues=@(Get-WsmReviewIssues $Workspace $PairId); $issues; if ($issues.Count) { exit 2 } }
            RulePreview { Get-WsmRulePreview $Workspace $PairId -Category $Category -Search $Search -Decision $Decision -Reason $Reason }
            ApplyRule { Invoke-WsmReviewRule $Workspace $PairId -Category $Category -Search $Search -Decision $Decision -Reason $Reason -ExpectedRevision $ExpectedRevision }
            ManualItem { Add-WsmManualItem $Workspace $PairId $Category $Name $NaturalKey $Owner $Evidence $ExpectedRevision }
            Mapping { Set-WsmMapping $Workspace $PairId $ItemId $Mapping $ExpectedRevision -Type $MappingType }
            Evidence { Set-WsmEvidence $Workspace $PairId $ItemId $Owner $Evidence $ExpectedRevision }
            Approve { Approve-WsmPlan $Workspace $PairId $Path $ExpectedRevision }
            FleetGraph { Export-WsmFleetGraph $Workspace $Path }
            ImportResult { Import-WsmStageResult $Workspace $Path $ExpectedHash }
            Capabilities { Get-WsmCapabilities }
            ConsistencyGroup { Set-WsmConsistencyGroup $Workspace $PairId ($ItemId.Split(',')) $Name $Owner $Evidence $ExpectedRevision }
            TemplatePreview { Get-WsmTemplatePreview $Workspace $PairId $Path $ExpectedHash }
            ApplyTemplate { Invoke-WsmReviewTemplate $Workspace $PairId $Path $ExpectedHash $ExpectedRevision }
            ExportTemplate { Export-WsmReviewTemplate $Workspace $PairId $ItemId $Path }
        }
        exit 0
    }
    if ([Console]::IsInputRedirected -or [Environment]::GetCommandLineArgs() -contains '-NonInteractive') { throw '非互動環境請指定 -Action；Menu 需要互動主控台。' }
    while ($true) {
        Write-Host "`nWindows Server Migration 0.3 — 盤點／審核／隔離 pilot 遷移"
        Write-Host '1 本機來源盤點  2 建立管理工作區  3 匯入盤點  4 審核／排除  5 分類 HTML'
        Write-Host '6 匯出 CSV  7 匯入 CSV  8 全批次報告  9 查詢阻擋項目  10 核准審核文件  11 補查證據／負責人'
        Write-Host '12 人工補列  13 路徑／帳號／端點映射  14 應用組合／內建分類  15 配對／波次規劃  16 跨主機相依  17 結果包匯入'
        Write-Host '18 循環相依的一致性群組  19 安全匯入盤點ZIP  20 匯出規則模板  21 預覽／套用模板  22 正式搬移／還原／切換階段  0 離開'
        $menuChoice=Read-Host '選項'
        if ($null -eq $menuChoice) { throw 'Console input ended.' }
        try {
            switch ($menuChoice) {
                '0' { exit 0 }
                '1' { $output=Read-MenuValue '來源盤點受控目錄（每台固定同一目錄；0 取消）';if($output -eq '0'){continue};$deep=(Read-MenuValue '包含 COM+／角色物件／服務與排程 ACL 的深層盤點？ YES／NO') -ceq 'YES';Export-WsmInventory -OutputDirectory $output -DeepDiscovery:$deep | Format-List }
                '2' { Initialize-WsmWorkspace $Workspace | Format-List }
                '3' { $file=Read-MenuValue 'inventory JSON 路徑'; $hash=Read-MenuValue '經可信管道取得的 SHA256'; $target=Read-MenuValue '新主機暫用名稱（新配對必填）'; Import-WsmInventory $Workspace $file $hash $target | Select-Object PairId,InventoryRevision,DecisionRevision | Format-List }
                '4' { Review-Pair (Select-Pair) }
                '5' { Export-WsmReport $Workspace (Select-Pair) (Read-MenuValue 'HTML 輸出路徑') }
                '6' { Export-WsmDecisions $Workspace (Select-Pair) (Read-MenuValue 'CSV 輸出路徑') }
                '7' { $selected=Select-Pair; $file=Read-MenuValue '已修改的 CSV 路徑'; $preview=Import-WsmDecisions $Workspace $selected $file -Preview; $preview | Select-Object Rows,Changed,DecisionRevision | Format-List; $preview.Changes | Select-Object -First 20 | Format-Table; if ((Read-MenuValue '整份 CSV 檢核後套用，輸入 APPLY') -ceq 'APPLY') { Import-WsmDecisions $Workspace $selected $file -ExpectedHash $preview.SourceHash | Out-Null } }
                '8' { Export-WsmFleetReport $Workspace (Read-MenuValue '全批次 HTML 輸出路徑') }
                '9' { Get-WsmReviewIssues $Workspace (Select-Pair) | Format-Table -Wrap }
                '10' { $selected=Select-Pair; $c=Get-WsmCatalog $Workspace $selected; Approve-WsmPlan $Workspace $selected (Read-MenuValue '核准 JSON 輸出路徑') $c.DecisionRevision | Format-List }
                '11' { $selected=Select-Pair; $c=Get-WsmCatalog $Workspace $selected; Set-WsmEvidence $Workspace $selected (Read-MenuValue '項目完整 ItemId（報告中可複製）') (Read-MenuValue '確認負責人') (Read-MenuValue '補查證據編號／文件位置與結論（勿填密碼）') $c.DecisionRevision }
                '12' { $selected=Select-Pair; $c=Get-WsmCatalog $Workspace $selected; Add-WsmManualItem $Workspace $selected (Read-MenuValue '類別') (Read-MenuValue '項目名稱') (Read-MenuValue '唯一自然鍵') (Read-MenuValue '負責人') (Read-MenuValue '證據參考') $c.DecisionRevision | Format-List }
                '13' { $selected=Select-Pair; $c=Get-WsmCatalog $Workspace $selected; $id=Read-MenuValue '完整 ItemId'; $type=Read-MenuValue 'Path／Account／Endpoint'; Set-WsmMapping $Workspace $selected $id (Read-MenuValue '映射目的地') $c.DecisionRevision -Type $type }
                '14' { $selected=Select-Pair; $c=Get-WsmCatalog $Workspace $selected; Set-WsmReviewMetadata $Workspace $selected (Read-MenuValue '完整 ItemId') (Read-MenuValue '應用組合名稱') (Read-MenuValue 'Unknown／SuggestedInternal／ConfirmedInternal／ConfirmedThirdParty') $c.DecisionRevision }
                '15' { $selected=Select-Pair; $c=Get-WsmCatalog $Workspace $selected; Set-WsmPairPlan $Workspace $selected (Read-MenuValue '負責人') (Read-MenuValue '波次') (Read-MenuValue '最終名稱') (Read-MenuValue '暫用IP') (Read-MenuValue '最終IP') (Read-MenuValue '網域') $c.DecisionRevision }
                '16' { $selected=Select-Pair; $c=Get-WsmCatalog $Workspace $selected; Write-Host '選擇相依主機'; $dep=Select-Pair; Set-WsmCrossHostDependency $Workspace $selected $dep -Evidence (Read-MenuValue '相依證據') -ExpectedRevision $c.DecisionRevision; Export-WsmFleetGraph $Workspace (Read-MenuValue '相依圖 JSON 輸出路徑') }
                '17' { Import-WsmStageResult $Workspace (Read-MenuValue '結果 JSON 路徑') (Read-MenuValue '可信 SHA256') }
                '18' { $selected=Select-Pair; $c=Get-WsmCatalog $Workspace $selected; Set-WsmConsistencyGroup $Workspace $selected ((Read-MenuValue '全部群組成員 ItemId，逗號分隔').Split(',')) (Read-MenuValue '一致性群組名称') (Read-MenuValue '負責人') (Read-MenuValue '停寫／啟用／回復程序證據') $c.DecisionRevision }
                '19' { Import-WsmInventoryArchive $Workspace (Read-MenuValue '盤點 ZIP 路徑') (Read-MenuValue '獨立可信 ZIP SHA256') (Read-MenuValue '新主機暫用名稱') | Select-Object PairId,InventoryRevision,DecisionRevision | Format-List }
                '20' { Export-WsmReviewTemplate $Workspace (Select-Pair) (Read-MenuValue '已套用規則的 RuleId') (Read-MenuValue '模板 JSON 輸出路徑') | Format-List }
                '21' { $selected=Select-Pair; $file=Read-MenuValue '模板 JSON 路徑'; $hash=Read-MenuValue '可信 SHA256'; $preview=Get-WsmTemplatePreview $Workspace $selected $file $hash; $preview | Select-Object Selected,Changed,DecisionRevision | Format-List; $preview.Sample | Format-Table; $preview.Conflicts | Format-Table; if ((Read-MenuValue '確認此台實際命中與衝突，輸入 APPLY') -ceq 'APPLY') { Invoke-WsmReviewTemplate $Workspace $selected $file $hash $preview.DecisionRevision | Format-List } }
                '22' { Show-WsmMigrationWizard $Workspace }
                default { Write-Host '無效選項。' }
            }
        } catch [OperationCanceledException] { Write-Host $_.Exception.Message } catch [IO.EndOfStreamException] { throw } catch { Write-Host ('操作失敗：'+$_.Exception.Message) -ForegroundColor Red;Get-WsmFailureDetails $_ | Format-List Category,NativeCode,Hint }
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    if ($_.Exception -is [IO.InvalidDataException] -or $_.Exception -is [Management.Automation.ParameterBindingException]) { exit 4 }
    if ($_.Exception -is [IO.EndOfStreamException]) { exit 3 }
    exit 1
}
