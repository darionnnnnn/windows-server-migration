#requires -Version 5.1
[CmdletBinding()] param(
    [ValidateSet('Menu','Inventory','Initialize','Import','Report','FleetReport','ExportCsv','ImportCsv','Issues')][string]$Action='Menu',
    [string]$Workspace,[string]$Path,[string]$ExpectedHash,[string]$TargetName,[string]$PairId)
$ErrorActionPreference='Stop'
if (-not $Workspace) { $Workspace=Join-Path $PSScriptRoot 'migration-workspace' }
Import-Module (Join-Path $PSScriptRoot 'src\WindowsServerMigration.psd1') -Force
function Select-Pair {
    $pairs=@((Get-WsmFleet $Workspace).Pairs)
    if (-not $pairs.Count) { throw '尚未匯入任何主機。' }
    for ($i=0;$i -lt $pairs.Count;$i++) { Write-Host ('{0}. {1} -> {2}' -f ($i+1),$pairs[$i].SourceName,$pairs[$i].TargetName) }
    $choice=0; if (-not [int]::TryParse((Read-Host '選擇主機編號'),[ref]$choice) -or $choice -lt 1 -or $choice -gt $pairs.Count) { throw '無效編號。' }
    $pairs[$choice-1].PairId
}
function Review-Pair([string]$SelectedPair) {
    $category=Read-Host '類別（留空為全部）'; $search=Read-Host '名稱包含文字（留空為全部）'; $page=1
    while ($true) {
        $view=Get-WsmItems $Workspace $SelectedPair -Category $category -Search $search -Page $page
        Write-Host ('共 {0} 筆，第 {1} 頁，審核版本 {2}' -f $view.Total,$page,$view.DecisionRevision)
        for ($i=0;$i -lt $view.Items.Count;$i++) { $r=$view.Items[$i]; Write-Host ('{0}. [{1}] [{2}] [{3}] {4}' -f ($i+1),$r.Category,$r.Status,$r.Decision,$r.Name) }
        $command=Read-Host 'n 下一頁 / p 上一頁 / i 納入 / e 排除 / u 撤銷最後決定 / q 返回'
        switch ($command) {
            'q' { return }
            'n' { if ($page*50 -lt $view.Total) { $page++ } }
            'p' { $page=[math]::Max(1,$page-1) }
            'u' { Undo-WsmDecision $Workspace $SelectedPair $view.DecisionRevision | Out-Null }
            { $_ -in @('i','e') } {
                $inputRows=Read-Host '輸入本頁編號，以逗號分隔；all 選取本頁全部（跨頁大量處理請使用 CSV）'
                $ids=@()
                if ($inputRows -eq 'all') { $ids=@($view.Items | ForEach-Object ItemId) }
                else { foreach ($v in $inputRows.Split(',')) { $number=0; if (-not [int]::TryParse($v.Trim(),[ref]$number) -or $number -lt 1 -or $number -gt $view.Items.Count) { throw '編號無效，尚未套用。' }; $ids+=$view.Items[$number-1].ItemId } }
                if (-not $ids.Count) { throw '沒有選取項目。' }
                $decision='Include'; if ($command -eq 'e') { $decision='Exclude' }
                $reason=Read-Host '理由（排除時必填）'
                Write-Host ('將 {0} 個項目設為 {1}' -f $ids.Count,$decision)
                if ((Read-Host '輸入 APPLY 套用') -ceq 'APPLY') { Set-WsmDecision $Workspace $SelectedPair $ids $decision $reason $view.DecisionRevision | Out-Null }
            }
        }
    }
}
try {
    if ($Action -ne 'Menu') {
        switch ($Action) {
            Inventory { Export-WsmInventory -OutputDirectory $Path }
            Initialize { Initialize-WsmWorkspace $Workspace }
            Import { Import-WsmInventory $Workspace $Path $ExpectedHash $TargetName }
            Report { Export-WsmReport $Workspace $PairId $Path }
            FleetReport { Export-WsmFleetReport $Workspace $Path }
            ExportCsv { Export-WsmDecisions $Workspace $PairId $Path }
            ImportCsv { Import-WsmDecisions $Workspace $PairId $Path }
            Issues { Get-WsmReviewIssues $Workspace $PairId }
        }
        exit 0
    }
    if ([Console]::IsInputRedirected -or [Environment]::GetCommandLineArgs() -contains '-NonInteractive') { throw '非互動環境請指定 -Action；Menu 需要互動主控台。' }
    while ($true) {
        Write-Host "`nWindows Server Migration 0.1 — 盤點／離線審核；還原尚未實作"
        Write-Host '1 本機來源盤點  2 建立管理工作區  3 匯入盤點  4 審核／排除  5 分類 HTML'
        Write-Host '6 匯出 CSV  7 匯入 CSV  8 全批次報告  9 查詢阻擋項目  10 核准審核文件  11 補查證據／負責人  0 離開'
        $menuChoice=Read-Host '選項'
        if ($null -eq $menuChoice) { throw 'Console input ended.' }
        try {
            switch ($menuChoice) {
                '0' { exit 0 }
                '1' { Export-WsmInventory -OutputDirectory (Read-Host '來源盤點受控目錄（每台固定同一目錄）') | Format-List }
                '2' { Initialize-WsmWorkspace $Workspace | Format-List }
                '3' { $file=Read-Host 'inventory JSON 路徑'; $hash=Read-Host '經可信管道取得的 SHA256'; $target=Read-Host '新主機暫用名稱（新配對必填）'; Import-WsmInventory $Workspace $file $hash $target | Select-Object PairId,InventoryRevision,DecisionRevision | Format-List }
                '4' { Review-Pair (Select-Pair) }
                '5' { Export-WsmReport $Workspace (Select-Pair) (Read-Host 'HTML 輸出路徑') }
                '6' { Export-WsmDecisions $Workspace (Select-Pair) (Read-Host 'CSV 輸出路徑') }
                '7' { $selected=Select-Pair; $file=Read-Host '已修改的 CSV 路徑'; Import-WsmDecisions $Workspace $selected $file -WhatIf; if ((Read-Host '整份 CSV 檢核後套用，輸入 APPLY') -ceq 'APPLY') { Import-WsmDecisions $Workspace $selected $file | Out-Null } }
                '8' { Export-WsmFleetReport $Workspace (Read-Host '全批次 HTML 輸出路徑') }
                '9' { Get-WsmReviewIssues $Workspace (Select-Pair) | Format-Table -Wrap }
                '10' { $selected=Select-Pair; $c=Get-WsmCatalog $Workspace $selected; Approve-WsmPlan $Workspace $selected (Read-Host '核准 JSON 輸出路徑') $c.DecisionRevision | Format-List }
                '11' { $selected=Select-Pair; $c=Get-WsmCatalog $Workspace $selected; Set-WsmEvidence $Workspace $selected (Read-Host '項目完整 ItemId（報告中可複製）') (Read-Host '確認負責人') (Read-Host '補查證據編號／文件位置與結論（勿填密碼）') $c.DecisionRevision }
                default { Write-Host '無效選項。' }
            }
        } catch { Write-Host ('操作失敗：'+$_.Exception.Message) -ForegroundColor Red }
    }
} catch { Write-Error $_; exit 1 }
