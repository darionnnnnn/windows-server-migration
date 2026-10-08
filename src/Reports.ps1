function Write-WsmHtml([string]$Path,[string]$Title,$Rows) {
    # Never embed raw collector settings (task actions/environment can contain credentials).
    $json=ConvertTo-Json -InputObject @($Rows) -Depth 8 -Compress
    $json=$json.Replace('<','\u003c').Replace('>','\u003e').Replace('&','\u0026')
    $safeTitle=[Net.WebUtility]::HtmlEncode($Title)
    $template=@'
<!doctype html><html lang="zh-Hant"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>__TITLE__</title><style>body{font:16px system-ui;margin:2rem;color:#182536}input,select,button{font:inherit;padding:.5rem;margin:.3rem}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccd;padding:.6rem;text-align:left;overflow-wrap:anywhere}th{background:#eaf0f7}.note{padding:1rem;background:#fff1cb}@media print{.controls{display:none}}</style>
<h1>__TITLE__</h1><p class="note">離線報告：僅顯示最後匯入的資料，不代表即時主機狀態。審核完成不代表可以自動還原。0.3 還原與切換僅限隔離 pilot；生產資格尚未驗收。</p>
<div class="controls"><label for="search">搜尋</label><input id="search"><label for="category">類別</label><select id="category"><option value="">全部</option></select><button id="prev">上一頁</button><button id="next">下一頁</button><button id="all">列印全部符合項目</button></div><p id="count"></p><table><thead id="head"></thead><tbody id="body"></tbody></table>
<script type="application/json" id="data">__DATA__</script><script>
'use strict';const rows=JSON.parse(document.getElementById('data').textContent);let page=0,full=false;const keys=rows.length?Object.keys(rows[0]):[];
const search=document.getElementById('search'),category=document.getElementById('category');
for(const c of [...new Set(rows.map(r=>r.Category||'Fleet'))].sort()){let o=document.createElement('option');o.value=c;o.textContent=c;category.appendChild(o)}
let hr=document.createElement('tr');for(const k of keys){let th=document.createElement('th');th.textContent=k;hr.appendChild(th)}document.getElementById('head').appendChild(hr);
function render(){let selected=rows.filter(r=>(!category.value||(r.Category||'Fleet')===category.value)&&Object.values(r).some(v=>String(v).toLowerCase().includes(search.value.toLowerCase())));page=Math.min(page,Math.max(0,Math.ceil(selected.length/100)-1));let shown=full?selected:selected.slice(page*100,(page+1)*100);document.getElementById('count').textContent=`符合 ${selected.length} / 全部 ${rows.length}；第 ${page+1} 頁，每頁 100 筆`;let b=document.getElementById('body');b.textContent='';for(const r of shown){let tr=document.createElement('tr');for(const k of keys){let td=document.createElement('td');td.textContent=r[k]===null?'':String(r[k]);tr.appendChild(td)}b.appendChild(tr)}}
search.oninput=category.onchange=()=>{page=0;full=false;render()};document.getElementById('prev').onclick=()=>{page=Math.max(0,page-1);full=false;render()};document.getElementById('next').onclick=()=>{page++;full=false;render()};document.getElementById('all').onclick=()=>{if(rows.length>2000){window.alert('超過 2,000 項，請使用同名 .html.txt 完整分类文件或先篩選，以免一次渲染全部資料造成瀏覽器卡住。');return;}full=true;render();window.print()};render();
</script></html>
'@
    $html=[regex]::Replace($template,'__TITLE__|__DATA__',{ param($match) if ($match.Value -eq '__TITLE__') { $safeTitle } else { $json } })
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path),$html,(New-Object Text.UTF8Encoding($false)))
}
function Export-WsmTextReport {
    param([string]$Workspace,[string]$PairId,[string]$Path)
    $c=Get-WsmCatalog $Workspace $PairId
    $writer=New-Object IO.StreamWriter([IO.Path]::GetFullPath($Path),$false,(New-Object Text.UTF8Encoding($false)))
    try {
        $writer.WriteLine(('Batch {0} / Pair {1} / Inventory {2} / Decision {3}' -f $c.BatchId,$PairId,$c.InventoryRevision,$c.DecisionRevision))
        $writer.WriteLine('Complete offline review; not proof of restoration. Raw settings omitted.')
        foreach ($category in $script:Categories) {
            $rows=@($c.Items | Where-Object Category -CEQ $category | Sort-Object Name,ItemId)
            $writer.WriteLine(('=== {0}: {1} ===' -f $category,$rows.Count))
            foreach ($i in $rows) { $writer.WriteLine(('{0} | {1} | {2} | {3} | {4}' -f $i.ItemId,$i.Kind,$i.Status,$i.Decision,$i.Name)); $writer.WriteLine(('Reason: {0} / Rule: {1} / Owner: {2} / Evidence: {3}' -f $i.Reason,$i.RuleId,$i.Owner,$i.Evidence)); $writer.WriteLine(('Path: {0} / Account: {1} / Endpoint: {2} / Group: {3}' -f $i.Mapping,$i.AccountMapping,$i.EndpointMapping,$i.ApplicationGroup)); foreach ($d in $i.Dependencies) { $writer.WriteLine(('Dependency: {0} / {1}' -f $d.ItemId,$d.Type)) } }
        }
    } finally { $writer.Dispose() }
}
function Export-WsmReport {
    param([string]$Workspace,[string]$PairId,[string]$Path)
    $c=Get-WsmCatalog $Workspace $PairId
    $rows=@($c.Items | Sort-Object Category,Name,ItemId | Select-Object Category,Kind,Name,ItemId,Status,Present,Decision,Reason,Mapping,AccountMapping,EndpointMapping,ApplicationGroup,BuiltIn,RuleId,Owner,Evidence,ConsistencyGroup,@{n='Dependencies';e={ @($_.Dependencies | ForEach-Object { $_.Type+':'+$_.ItemId }) -join '; ' }},@{n='Restoration';e={if($_.PSObject.Properties['MigrationSpec'] -and $_.MigrationSpec){$_.MigrationSpec.Adapter+' / IsolatedPilot; production unverified'}else{'Migration specification required'}}})
    $approval='NotApproved'; if ($c.Approval) { $approval=$c.Approval.ApprovalId }
    Write-WsmHtml $Path ($c.Source.Name+' -> '+$c.TargetName+' / batch '+$c.BatchId+' / pair '+$PairId+' / inventory '+$c.InventoryRevision+' / review '+$c.DecisionRevision+' / approval '+$approval+' / generation NotStarted / received '+$c.ImportedUtc+' / generated '+(Get-WsmUtc)) $rows
    Export-WsmTextReport $Workspace $PairId ($Path+'.txt')
    $raw=[Uri]([IO.Path]::GetFullPath((Get-WsmCatalogPath $Workspace $PairId)))
    $links='<p>完整分類文字清單：'+[Net.WebUtility]::HtmlEncode([IO.Path]::GetFileName($Path+'.txt'))+'。敏感原始證據（限有權限人員）：<a href="'+[Net.WebUtility]::HtmlEncode($raw.AbsoluteUri)+'">受控 catalog JSON</a>；請勿轉寄原始設定。</p>'
    $html=[IO.File]::ReadAllText($Path); [IO.File]::WriteAllText($Path,$html.Replace('<div class="controls">',$links+'<div class="controls">'),(New-Object Text.UTF8Encoding($false)))
}
function Export-WsmFleetReport {
    param([string]$Workspace,[string]$Path,[ValidateRange(1,720)][int]$StaleAfterHours=24)
    $f=Get-WsmFleet $Workspace
    $rows=@(foreach ($p in $f.Pairs) {
        $c=Get-WsmCatalog $Workspace $p.PairId
        $age=([DateTime]::UtcNow-[DateTime]::Parse($c.ImportedUtc).ToUniversalTime()).TotalHours
        $owner=''; $wave=''; if ($c.PSObject.Properties['PairPlan']) { $owner=$c.PairPlan.Owner; $wave=$c.PairPlan.Wave }
        $stage='Inventory'; $status='Received'; if ($c.PSObject.Properties['StageResults'] -and $c.StageResults.Count) { $r=$c.StageResults | Select-Object -Last 1; $stage=$r.Stage; $status=$r.Status; if ($r.InventoryRevision -ne $c.InventoryRevision -or $r.DecisionRevision -ne $c.DecisionRevision) { $status='StaleEvidence' } }
        $evidenceAge=$age;if($c.PSObject.Properties['EvidenceUtc']){$evidenceAge=([DateTime]::UtcNow-[DateTime]::Parse($c.EvidenceUtc).ToUniversalTime()).TotalHours};$stageAge=$null;if($c.PSObject.Properties['StageResults'] -and $c.StageResults.Count){$lastResult=$c.StageResults | Select-Object -Last 1;$stageAge=([DateTime]::UtcNow-[DateTime]::Parse($lastResult.ProducedUtc).ToUniversalTime()).TotalHours}
        $edges=''; if ($c.PSObject.Properties['CrossHostDependencies']) { $edges=@($c.CrossHostDependencies | ForEach-Object { $_.Type+':'+$_.PairId }) -join '; ' }
        [pscustomobject][ordered]@{ Source=$c.Source.Name; Target=$c.TargetName; PairId=$p.PairId; ReceivedUtc=$c.ImportedUtc; AgeHours=[math]::Round($age,1); EvidenceAgeHours=[Math]::Round($evidenceAge,1);StageAgeHours=$stageAge;StageStale=($null -ne $stageAge -and $stageAge -gt $StaleAfterHours);Stale=($age -gt $StaleAfterHours -or $evidenceAge -gt $StaleAfterHours); ClockSkew=($age -lt -0.0833 -or $evidenceAge -lt -0.0833); Owner=$owner; Wave=$wave; Stage=$stage; Status=$status; CrossHostDependencies=$edges; InventoryRevision=$c.InventoryRevision; DecisionRevision=$c.DecisionRevision; Total=@($c.Items).Count; Pending=@($c.Items | Where-Object Decision -EQ Pending).Count; Included=@($c.Items | Where-Object Decision -EQ Include).Count; Excluded=@($c.Items | Where-Object Decision -EQ Exclude).Count; ReviewApproved=($null -ne $c.Approval); PilotPlanApproved=($c.Approval -and $c.Approval.PSObject.Properties['Kind'] -and $c.Approval.Kind -eq 'MigrationPlan');ExportReady=$false; RestoreSupported=$false; NextStep='Complete review / validate role-specific adapters' }
    })
    Write-WsmHtml $Path ('Fleet '+$f.BatchId+' / generated '+(Get-WsmUtc)) $rows
}
