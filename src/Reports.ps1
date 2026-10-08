function Write-WsmHtml([string]$Path,[string]$Title,$Rows) {
    # Never embed raw collector settings (task actions/environment can contain credentials).
    $json=ConvertTo-Json -InputObject @($Rows) -Depth 8 -Compress
    $json=$json.Replace('<','\u003c').Replace('>','\u003e').Replace('&','\u0026')
    $safeTitle=[Net.WebUtility]::HtmlEncode($Title)
    $template=@'
<!doctype html><html lang="zh-Hant"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>__TITLE__</title><style>body{font:16px system-ui;margin:2rem;color:#182536}input,select,button{font:inherit;padding:.5rem;margin:.3rem}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccd;padding:.6rem;text-align:left;overflow-wrap:anywhere}th{background:#eaf0f7}.note{padding:1rem;background:#fff1cb}@media print{.controls{display:none}}</style>
<h1>__TITLE__</h1><p class="note">離線報告：僅顯示最後匯入的資料，不代表即時主機狀態。審核完成不代表可以自動還原。本版未實作還原。</p>
<div class="controls"><label>搜尋 <input id="search"></label><label>類別 <select id="category"><option value="">全部</option></select></label><button id="prev">上一頁</button><button id="next">下一頁</button><button id="all">列印全部符合項目</button></div><p id="count"></p><table><thead id="head"></thead><tbody id="body"></tbody></table>
<script type="application/json" id="data">__DATA__</script><script>
'use strict';const rows=JSON.parse(document.getElementById('data').textContent);let page=0,full=false;const keys=rows.length?Object.keys(rows[0]):[];
const search=document.getElementById('search'),category=document.getElementById('category');
for(const c of [...new Set(rows.map(r=>r.Category||'Fleet'))].sort()){let o=document.createElement('option');o.value=c;o.textContent=c;category.appendChild(o)}
let hr=document.createElement('tr');for(const k of keys){let th=document.createElement('th');th.textContent=k;hr.appendChild(th)}document.getElementById('head').appendChild(hr);
function render(){let selected=rows.filter(r=>(!category.value||(r.Category||'Fleet')===category.value)&&Object.values(r).some(v=>String(v).toLowerCase().includes(search.value.toLowerCase())));page=Math.min(page,Math.max(0,Math.ceil(selected.length/100)-1));let shown=full?selected:selected.slice(page*100,(page+1)*100);document.getElementById('count').textContent=`符合 ${selected.length} / 全部 ${rows.length}；第 ${page+1} 頁，每頁 100 筆`;let b=document.getElementById('body');b.textContent='';for(const r of shown){let tr=document.createElement('tr');for(const k of keys){let td=document.createElement('td');td.textContent=r[k]===null?'':String(r[k]);tr.appendChild(td)}b.appendChild(tr)}}
search.oninput=category.onchange=()=>{page=0;full=false;render()};document.getElementById('prev').onclick=()=>{page=Math.max(0,page-1);full=false;render()};document.getElementById('next').onclick=()=>{page++;full=false;render()};document.getElementById('all').onclick=()=>{full=true;render();window.print()};render();
</script></html>
'@
    $html=$template.Replace('__TITLE__',$safeTitle).Replace('__DATA__',$json)
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path),$html,(New-Object Text.UTF8Encoding($false)))
}
function Export-WsmReport {
    param([string]$Workspace,[string]$PairId,[string]$Path)
    $c=Get-WsmCatalog $Workspace $PairId
    $rows=@($c.Items | Sort-Object Category,Name,ItemId | Select-Object Category,Kind,Name,ItemId,Status,Present,Decision,Reason,Mapping,Owner,Evidence,@{n='Restoration';e={'Manual / adapter not implemented'}})
    Write-WsmHtml $Path ($c.Source.Name+' -> '+$c.TargetName+' / inventory '+$c.InventoryRevision+' / review '+$c.DecisionRevision+' / received '+$c.ImportedUtc) $rows
}
function Export-WsmFleetReport {
    param([string]$Workspace,[string]$Path)
    $f=Get-WsmFleet $Workspace
    $rows=@(foreach ($p in $f.Pairs) {
        $c=Get-WsmCatalog $Workspace $p.PairId
        [pscustomobject][ordered]@{ Source=$c.Source.Name; Target=$c.TargetName; PairId=$p.PairId; ReceivedUtc=$c.ImportedUtc; AgeHours=[math]::Round(([DateTime]::UtcNow-[DateTime]::Parse($c.ImportedUtc).ToUniversalTime()).TotalHours,1); InventoryRevision=$c.InventoryRevision; DecisionRevision=$c.DecisionRevision; Total=@($c.Items).Count; Pending=@($c.Items | Where-Object Decision -EQ Pending).Count; Included=@($c.Items | Where-Object Decision -EQ Include).Count; Excluded=@($c.Items | Where-Object Decision -EQ Exclude).Count; ReviewApproved=($null -ne $c.Approval); ExportReady=$false; RestoreSupported=$false }
    })
    Write-WsmHtml $Path ('Fleet '+$f.BatchId+' / generated '+(Get-WsmUtc)) $rows
}
