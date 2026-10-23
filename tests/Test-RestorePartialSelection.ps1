#requires -Version 5.1
# N1 驗收 15.6-6：部分選取後，用真實 handler（Create-WsmWizardTargetDecisionReceipt、Get-WsmWizardTargetRestoreProjection、
# Invoke-WsmWizardTargetRestore）驗證「決策收據的 SelectedItemIds」「預覽 Ready 的寫入項目」「還原結果」「目標端實際寫入」四者一致，
# 且未勾選項目的目標路徑不存在。沿用 Test-WizardRestore 的真實封裝流程（真實 ZIP／目錄匯入、真實收據、真實還原），
# 只在收據與預覽之後、其餘情境之前插入探針，探針跑完即結束該副本。
# -InjectUnselectedWrite 是突變用的替身：讓寫入器多寫一個未勾選項目的目標，本測試必須因此失敗。
[CmdletBinding()]
param([switch]$InjectUnselectedWrite)
$ErrorActionPreference='Stop'
$restoreTestPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Test-WizardRestore.ps1'))
if(-not [IO.File]::Exists($restoreTestPath)){throw 'Required real Test-WizardRestore fixture is missing.'}
$source=[IO.File]::ReadAllText($restoreTestPath)
$needle="        # R6: 項目選擇器的檔數／位元組／相依與預覽的新欄位"
if(([regex]::Matches($source,[regex]::Escape($needle))).Count -ne 1){throw 'Could not uniquely locate the partial-selection point in the Test-WizardRestore fixture.'}
$leak=if($InjectUnselectedWrite){'$true'}else{'$false'}
$probe=@'
        # ---- N1 探針（由 Test-RestorePartialSelection.ps1 插入）：收據只選 item、item2；item3（有備份內容、可還原）與 item4 未勾選。
        $n1Context=Assert-WsmWizardTargetRole $work $pair;$n1Package=Get-WsmWizardTargetPackage $work $pair $n1Context $allJobs
        $n1Decision=Get-WsmWizardTargetDecisionRecord $work $pair ([string]$n1Context.Received.SHA256)
        $n1Selected=@($n1Decision.Receipt.SelectedItemIds|ForEach-Object {[string]$_}|Sort-Object)
        $n1Expected=@([string]$item.ItemId,[string]$item2.ItemId|Sort-Object)
        Check (($n1Selected -join ',') -ceq ($n1Expected -join ',')) 'N1: the receipt must carry exactly the partial selection.'
        $n1Options=@(Get-WsmWizardTargetItemOptions $n1Context $n1Package $null $n1Decision);$n1By=@{};foreach($n1Option in $n1Options){$n1By[[string]$n1Option.value]=$n1Option}
        foreach($n1Id in @($item.ItemId,$item2.ItemId,$item3.ItemId)){Check ($n1By[[string]$n1Id].restorable -eq $true -and [string]$n1By[[string]$n1Id].restorableCode -ceq '') ('N1: approved item '+$n1Id+' with payload and a placeable target must be restorable.')}
        Check ($n1By[[string]$item.ItemId].preselected -eq $true -and $n1By[[string]$item2.ItemId].preselected -eq $true -and $n1By[[string]$item3.ItemId].preselected -eq $false -and $n1By[[string]$item4.ItemId].preselected -eq $false) 'N1: options must preselect exactly the receipt selection.'
        $n1ReadyWrite=@($preview.Rows|Where-Object {[string]$_.Status -ceq 'Ready' -and [string]$_.Action -notlike 'Verify*'}|ForEach-Object {[string]$_.ItemId}|Sort-Object)
        Check (($n1ReadyWrite -join ',') -ceq ($n1Selected -join ',')) 'N1: the preview Ready write items must equal the receipt selection.'
        foreach($n1Unselected in @($item3.ItemId,$item4.ItemId)){$n1Row=@($preview.Rows|Where-Object ItemId -CEQ ([string]$n1Unselected));Check ($n1Row.Count -eq 1 -and [string]$n1Row[0].Action -ceq 'DeferredBySelection') ('N1: unselected item '+$n1Unselected+' must be DeferredBySelection in the preview.')}
        $n1UnselectedPaths=@($targetRoot3,[string]$fileSpec4.TargetPath)
        foreach($n1Path in $n1UnselectedPaths){Check (-not [IO.Directory]::Exists($n1Path) -and -not [IO.File]::Exists($n1Path)) ('N1: unselected target already exists before the restore: '+$n1Path)}
        $n1Leak=__LEAK__
        if($n1Leak){
            # 替身：寫入器在正常還原之後，多寫一個未勾選項目的目標。
            $script:n1OriginalWriter=(Get-Command Invoke-WsmAssistiveFileScopeRestore -CommandType Function).ScriptBlock;$script:n1LeakRoot=$targetRoot3
            function script:Invoke-WsmAssistiveFileScopeRestore {$n1Result=& $script:n1OriginalWriter @args;[void][IO.Directory]::CreateDirectory($script:n1LeakRoot);[IO.File]::WriteAllText((Join-Path $script:n1LeakRoot 'state.bin'),'leaked unselected write');$n1Result}
        }
        $n1Restored=Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash $preview.PreviewHash -Jobs $allJobs
        $n1ResultIds=@($n1Restored.ItemResults|ForEach-Object {[string]$_.ItemId}|Sort-Object -Unique)
        Check (($n1ResultIds -join ',') -ceq ($n1Selected -join ',')) ('N1: the restore result items ('+($n1ResultIds -join ',')+') must equal the receipt selection ('+($n1Selected -join ',')+').')
        $n1Succeeded=@($n1Restored.ItemResults|Where-Object {[string]$_.Status -ceq 'Succeeded'}|ForEach-Object {[string]$_.ItemId}|Sort-Object -Unique)
        Check (@($n1Succeeded|Where-Object {$n1ReadyWrite -notcontains $_}).Count -eq 0 -and ($n1Succeeded -contains [string]$item.ItemId) -and ($n1Succeeded -notcontains [string]$item2.ItemId)) 'N1: the actually written items must be a subset of the preview Ready write items (item written, conflicting item2 left alone).'
        # 目標端實際寫入：被寫入者有內容、衝突者原封不動、未勾選者路徑不存在。
        Check ((Get-FileHash -LiteralPath (Join-Path $targetRoot 'state.bin') -Algorithm SHA256).Hash -ieq $blob.Hash) 'N1: the selected restorable item was not written with its exact payload.'
        Check ((Get-FileHash -LiteralPath $targetFile2 -Algorithm SHA256).Hash -ieq [string]$preexistingHash -and @(Get-ChildItem -LiteralPath $targetRoot2 -Recurse -Force).Count -eq 1) 'N1: the conflicting selected item changed or gained Target files.'
        foreach($n1Path in $n1UnselectedPaths){Check (-not [IO.Directory]::Exists($n1Path) -and -not [IO.File]::Exists($n1Path)) ('N1: an unselected item has a Target path after the restore: '+$n1Path+' (receipt selection and actual writes differ).')}
        # 嘗試紀錄綁定同一份收據；選項在還原後只把真正成功的項目標為已還原。
        $n1Paths=Get-WsmOperationPaths (Join-Path $work 'pairs') $pair;$n1State=Get-WsmOperationState $n1Paths $n1Package.Package
        Check ([string]$n1State.RestoreAttempt.DecisionReceiptHash -ieq [string]$n1Decision.SHA256) 'N1: the durable restore attempt must bind the same decision receipt that carries the selection.'
        $n1After=@(Get-WsmWizardTargetItemOptions $n1Context $n1Package $n1State $n1Decision);$n1AfterBy=@{};foreach($n1Option in $n1After){$n1AfterBy[[string]$n1Option.value]=$n1Option}
        Check ($n1AfterBy[[string]$item.ItemId].restored -eq $true -and $n1AfterBy[[string]$item2.ItemId].restored -eq $false -and $n1AfterBy[[string]$item3.ItemId].restored -eq $false) 'N1: after the partial restore only the written item may be marked restored.'
        Write-Host 'PASS: N1 partial selection — receipt SelectedItemIds, preview Ready write items, restore results and Target bytes agree; unselected targets do not exist.'
        return
'@.Replace('__LEAK__',$leak)
$source=$source.Replace($needle,$probe+[Environment]::NewLine+$needle)
$probePath=Join-Path $PSScriptRoot ('Test-WizardRestore.N1Probe-'+[Guid]::NewGuid().ToString('N')+'.ps1')
try{
    [IO.File]::WriteAllText($probePath,$source,(New-Object Text.UTF8Encoding($true)))
    $output=@(& $probePath *>&1)
    $marker=@($output|Where-Object {([string]$_) -like 'PASS: N1 partial selection*'})
    if($marker.Count -ne 1){throw ('Partial-selection probe did not report its assertions: '+(($output|Select-Object -Last 8) -join [Environment]::NewLine))}
    Write-Host ([string]$marker[0])
}finally{if([IO.File]::Exists($probePath)){Remove-Item -LiteralPath $probePath -Force}}
