#requires -Version 5.1
# R24: the offline report's per-file drill-down is bounded twice: at most 200 files per backed item and at most 5000 entries in the whole report.
# A backup with a huge number of files must not make the results document or the report grow without limit, and every path the report prints
# has gone through the shared safe-text rules. This is the data/HTML-level test; the browser behaviour (expand, keyboard, no-JS, 320/390px) is in Test-OfflineReportBrowser.js.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$dir=Join-Path ([IO.Path]::GetTempPath()) ('wsm-r24-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($dir)
try {
    & $module {
        param($Dir)
        $script:ToolVersion='fixture'
        $check={param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
        $item={param([string]$Id,[string]$Name)[pscustomobject]@{ItemId=$Id;Name=$Name;Kind='DataRoot';Category='Storage';NaturalKey=('key-'+$Id);Settings=[pscustomobject]@{Path=('C:\settings\'+$Id)};Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath='D:\scope\C';TransferChannel='C'};Dependencies=@()}}
        $limitItem=[int]$script:WsmOfflineReportFileListItemLimit;$limitTotal=[int]$script:WsmOfflineReportFileListTotalLimit
        & $check ($limitItem -eq 200 -and $limitTotal -eq 5000) 'R24: the documented limits are 200 per item and 5000 in total.'

        # ---- 1) per-item limit and boundary cases: 0 files (configuration only is not part of this), 199, 200, 201 and 300 files ----
        $plan=New-Object 'System.Collections.Generic.List[object]';$artifacts=New-Object 'System.Collections.Generic.List[object]'
        $sizes=[ordered]@{'item-a'=1;'item-b'=199;'item-c'=200;'item-d'=201;'item-e'=300}
        foreach($id in $sizes.Keys){
            $plan.Add((& $item $id $id))
            for($n=1;$n -le [int]$sizes[$id];$n++){$artifacts.Add([pscustomobject]@{ItemId=$id;RelativePath=('f{0:D4}.dat' -f $n);Directory=$false;Data=[pscustomobject]@{Bytes=(100+$n)}})}
            $artifacts.Add([pscustomobject]@{ItemId=$id;RelativePath='emptydir';Directory=$true})
        }
        $rows=@(Get-WsmBackupItemResultRows ([pscustomobject]@{Items=@($plan.ToArray())}) $null @($artifacts.ToArray()) $false)
        $software=[pscustomobject]@{SoftwareRows=@();FeatureRows=@();CoverageGaps=@()}
        $meta=[pscustomobject]@{PairId='fixture-pair';AttemptId='fixture-attempt';PlanHash=('b'*64);ManifestHash=('a'*64);InventorySource='TrustedInventory';Software=$software}
        $resultsPath=Join-Path $Dir 'backup-item-results.json'
        $export=Export-WsmBackupItemResults $resultsPath $rows $meta
        $document=Read-WsmJson $resultsPath
        & $check ([bool]$document.PSObject.Properties['FileLists']) 'R24: the results document has a FileLists section.'
        $lists=@{};foreach($list in @($document.FileLists)){$lists[[string]$list.ItemId]=$list}
        foreach($id in $sizes.Keys){
            $expectedListed=[Math]::Min([int]$sizes[$id],200)
            & $check ($lists.ContainsKey($id)) ('R24: '+$id+' has a file list.')
            & $check ([long]$lists[$id].Total -eq [long]$sizes[$id]) ('R24: '+$id+' total is the true file count (directories are not files); got '+$lists[$id].Total)
            & $check (@($lists[$id].Entries).Count -eq $expectedListed -and [int]$lists[$id].Listed -eq $expectedListed) ('R24: '+$id+' lists min(total,200)='+$expectedListed+'; got '+@($lists[$id].Entries).Count)
            & $check ([string]$lists[$id].Omitted -ceq '') ('R24: '+$id+' is not omitted by the report limit.')
        }
        & $check ([string]$lists['item-d'].Entries[0].Path -ceq 'f0001.dat' -and [string]$lists['item-d'].Entries[199].Path -ceq 'f0200.dat') 'R24: the list is the first 200 files in index order.'
        $docRow=@($document.Rows)[0]
        & $check (-not $docRow.PSObject.Properties['FileSample']) 'R24: FileSample never leaks into the result rows (the workbench view reads those rows).'
        $reportPath=Join-Path $Dir 'backup-report.html'
        [void](Export-WsmBackupOfflineReport $resultsPath $export.SHA256 $reportPath)
        $html=[IO.File]::ReadAllText($reportPath)
        & $check (([regex]::Matches($html,'<details class="file-detail">')).Count -eq 5) 'R24: every backed item has exactly one details element.'
        & $check ($html -match [regex]::Escape((([string][char]0x53E6)+([string][char]0x6709)+' 100 '))) 'R24: the 300-file item says 100 files are not listed (300-200).'
        & $check ($html -match [regex]::Escape((([string][char]0x53E6)+([string][char]0x6709)+' 1 '))) 'R24: the 201-file item says 1 file is not listed.'
        $moreCount=([regex]::Matches($html,'class="file-more"')).Count
        & $check ($moreCount -eq 2) ('R24: only the two items above 200 files carry the remainder hint; got '+$moreCount)
        Write-Host 'PASS: R24 per-item limit (1, 199, 200, 201, 300 files), directories not counted, FileSample not in rows.'

        # ---- 2) whole-report limit: 40 items x 300 files = 12000 files must stay within 5000 entries and a bounded HTML size ----
        $plan2=New-Object 'System.Collections.Generic.List[object]';$artifacts2=New-Object 'System.Collections.Generic.List[object]'
        for($i=1;$i -le 40;$i++){
            $id=('big-{0:D2}' -f $i);$plan2.Add((& $item $id $id))
            for($n=1;$n -le 300;$n++){$artifacts2.Add([pscustomobject]@{ItemId=$id;RelativePath=('dir\sub\file-{0:D4}.dat' -f $n);Directory=$false;Data=[pscustomobject]@{Bytes=(100+$n)}})}
        }
        $rows2=@(Get-WsmBackupItemResultRows ([pscustomobject]@{Items=@($plan2.ToArray())}) $null @($artifacts2.ToArray()) $false)
        $resultsPath2=Join-Path $Dir 'big-results.json'
        $export2=Export-WsmBackupItemResults $resultsPath2 $rows2 $meta
        $document2=Read-WsmJson $resultsPath2
        $lists2=@($document2.FileLists)
        $listedTotal=0;foreach($list in $lists2){$listedTotal+=@($list.Entries).Count;& $check (@($list.Entries).Count -le 200) 'R24: no item exceeds 200 entries.';& $check ([long]$list.Total -eq 300) 'R24: the total stays the true count even when entries are not listed.'}
        & $check ($listedTotal -le 5000) ('R24: the whole document holds at most 5000 entries; got '+$listedTotal)
        & $check ($listedTotal -eq 5000) ('R24: the budget is used up (12000 files available); got '+$listedTotal)
        $omitted=@($lists2 | Where-Object {[string]$_.Omitted -ceq 'ReportLimit'})
        & $check ($omitted.Count -ge 15) ('R24: items that did not fit the budget are flagged ReportLimit; got '+$omitted.Count)
        & $check (@($omitted | Where-Object {[int]$_.Listed -gt 0 -and [int]$_.Listed -lt 200}).Count -le 1) 'R24: at most one item is partially listed (the one that hits the budget).'
        $reportPath2=Join-Path $Dir 'big-report.html'
        [void](Export-WsmBackupOfflineReport $resultsPath2 $export2.SHA256 $reportPath2)
        $size=(Get-Item -LiteralPath $reportPath2).Length
        & $check ($size -lt 3MB) ('R24: the report stays bounded (<3 MiB) with 12000 files; got '+$size+' bytes.')
        $html2=[IO.File]::ReadAllText($reportPath2)
        & $check (([regex]::Matches($html2,'<li><code>')).Count -le 5000) 'R24: the report prints at most 5000 file entries.'
        & $check ($html2.Contains('artifacts '+[string][char]0x7D22+[string][char]0x5F15)) 'R24: omitted items point at the workbench or the artifacts index.'
        Write-Host ('PASS: R24 whole-report limit (12000 files -> '+$listedTotal+' entries, '+$omitted.Count+' items flagged, report '+[math]::Round($size/1KB)+' KiB).')

        # ---- 3) safe text: control and bidi characters become visible markers before they reach the document ----
        $hostile=@(('a'+[string][char]0x202e+'b.txt'),("x`ty.txt"),('=cmd'),('p'*400+'.dat'))
        $plan3=@((& $item 'safe-1' 'safe-1'));$artifacts3=@(foreach($name in $hostile){[pscustomobject]@{ItemId='safe-1';RelativePath=$name;Directory=$false;Data=[pscustomobject]@{Bytes=1}}})
        $rows3=@(Get-WsmBackupItemResultRows ([pscustomobject]@{Items=$plan3}) $null $artifacts3 $false)
        $entries=@($rows3[0].FileSample.Entries | ForEach-Object {[string]$_.Path})
        & $check (-not ($entries -join '').Contains([string][char]0x202e)) 'R24: the right-to-left override is not stored raw.'
        & $check ($entries[0].Contains('\u202E')) 'R24: the override is stored as a visible marker.'
        & $check ($entries[1].Contains('\u0009') -and -not $entries[1].Contains("`t")) 'R24: a tab is stored as a visible marker.'
        & $check ($entries[3].EndsWith([string][char]0x2026+[string][char]0xFF08+[string][char]0x5DF2+[string][char]0x622A+[string][char]0x65B7+[string][char]0xFF09)) 'R24: an over-long path is explicitly marked as truncated.'
        Write-Host 'PASS: R24 paths are stored through the shared safe-text rules (bidi/control visible, truncation marked).'
    } $dir
    Write-Host 'PASS: R24 offline report file lists.'
}
finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
