function Write-WsmHtml([string]$Path,[string]$Title,$Rows,[string]$ReviewLinks='') {
    # Never embed raw collector settings (task actions/environment can contain credentials).
    $allRows=$Rows;if($null -eq $Rows){$allRows=@()}elseif($Rows -isnot [Array]){$allRows=@($Rows)}
    $chunkSize=250
    $count=$allRows.Count
    $keys=@();if($count){$keys=@($allRows[0].PSObject.Properties | ForEach-Object Name)}
    $categories=@($allRows | ForEach-Object {if($_.PSObject.Properties['Category'] -and $_.Category){[string]$_.Category}else{'Fleet'}} | Sort-Object -Unique)
    $summary=@(foreach($category in $categories){$categoryRows=@($allRows | Where-Object {if($_.PSObject.Properties['Category'] -and $_.Category){[string]$_.Category -ceq $category}else{'Fleet' -ceq $category}});$decisionRows=@($categoryRows | Where-Object {$_.PSObject.Properties['Decision'] -and [string]$_.Decision -in @('Include','Exclude','Pending')});if($decisionRows.Count){[pscustomobject][ordered]@{Category=$category;Total=$categoryRows.Count;Include=@($decisionRows | Where-Object Decision -CEQ Include).Count;Exclude=@($decisionRows | Where-Object Decision -CEQ Exclude).Count;Pending=@($decisionRows | Where-Object Decision -CEQ Pending).Count;NotApplicable=($categoryRows.Count-$decisionRows.Count)}}else{[pscustomobject][ordered]@{Category=$category;Total=$categoryRows.Count;Include='N/A';Exclude='N/A';Pending='N/A';NotApplicable=$categoryRows.Count}}})
    $metadataJson=ConvertTo-Json -InputObject ([pscustomobject][ordered]@{Count=$count;ChunkSize=$chunkSize;Keys=$keys;Categories=$categories}) -Depth 5 -Compress
    $summaryJson=ConvertTo-Json -InputObject @($summary) -Depth 5 -Compress
    $metadataJson=$metadataJson.Replace('<','\u003c').Replace('>','\u003e').Replace('&','\u0026')
    $summaryJson=$summaryJson.Replace('<','\u003c').Replace('>','\u003e').Replace('&','\u0026')
    $safeTitle=[Net.WebUtility]::HtmlEncode($Title)
    $template=@'
<!doctype html><html lang="zh-Hant"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>__TITLE__</title><style>body{font:16px system-ui;margin:2rem;color:#182536}input,select,button{font:inherit;padding:.5rem;margin:.3rem}table{border-collapse:collapse;width:100%;margin:.8rem 0 1.5rem}td,th{border:1px solid #ccd;padding:.6rem;text-align:left;overflow-wrap:anywhere}th{background:#eaf0f7}.note{padding:1rem;background:#fff1cb}@media print{.controls{display:none}}</style>
<h1>__TITLE__</h1><p class="note">離線報告：僅顯示最後匯入的資料，不代表即時主機狀態。審核完成不代表可以自動還原。0.3 還原與切換僅限隔離 pilot；生產資格尚未驗收。</p>
<h2>分類決策小計</h2><table><thead id="summary-head"></thead><tbody id="summary"></tbody></table>
__LINKS__<div class="controls"><label for="search">搜尋</label><input id="search"><label for="category">類別</label><select id="category"><option value="">全部</option></select><button id="prev">上一頁</button><button id="next">下一頁</button><button id="all">列印全部符合項目</button></div><p id="count"></p><table><thead id="head"></thead><tbody id="body"></tbody></table>
<script type="application/json" id="metadata">__META__</script><script type="application/json" id="summary-data">__SUMMARY__</script>__CHUNKS__<script>
'use strict';const meta=JSON.parse(document.getElementById('metadata').textContent);const summary=JSON.parse(document.getElementById('summary-data').textContent);let page=0,full=false,matches=null,scanVersion=0,scanning=false;const keys=meta.Keys,total=meta.Count,chunkSize=meta.ChunkSize,cache=new Map(),cacheLimit=4;
const search=document.getElementById('search'),category=document.getElementById('category');
for(const c of meta.Categories){const o=document.createElement('option');o.value=c;o.textContent=c;category.appendChild(o)}
function buildTableHeader(target,names){const tr=document.createElement('tr');for(const name of names){const th=document.createElement('th');th.textContent=name;tr.appendChild(th)}target.appendChild(tr)}
buildTableHeader(document.getElementById('summary-head'),summary.length?Object.keys(summary[0]):[]);const summaryBody=document.getElementById('summary');for(const row of summary){const tr=document.createElement('tr');for(const k of Object.keys(row)){const td=document.createElement('td');td.textContent=row[k]===null?'':String(row[k]);tr.appendChild(td)}summaryBody.appendChild(tr)}
buildTableHeader(document.getElementById('head'),keys);
function chunkRows(index){if(cache.has(index)){const value=cache.get(index);cache.delete(index);cache.set(index,value);return value}const node=document.getElementById('chunk-'+index);if(!node)throw new Error('Offline report chunk is missing: '+index);const rows=JSON.parse(node.textContent);if(cache.size>=cacheLimit)cache.delete(cache.keys().next().value);cache.set(index,rows);return rows}
function matchCount(){return matches===null?total:matches.length}
function render(){const count=matchCount(),pages=Math.max(1,Math.ceil(count/100));page=Math.min(page,pages-1);const body=document.getElementById('body');body.textContent='';if(scanning){document.getElementById('count').textContent='正在搜尋完整離線清單…';return}const first=full?0:page*100,last=full?count:Math.min(count,first+100);for(let pos=first;pos<last;pos++){const ordinal=matches===null?pos:matches[pos],rows=chunkRows(Math.floor(ordinal/chunkSize)),row=rows[ordinal%chunkSize],tr=document.createElement('tr');for(const k of keys){const td=document.createElement('td');td.textContent=row[k]===null||row[k]===undefined?'':String(row[k]);tr.appendChild(td)}body.appendChild(tr)}document.getElementById('count').textContent=`符合 ${count} / 全部 ${total}；第 ${count?page+1:0} 頁，每頁 100 筆`}
function yieldTurn(){return new Promise(resolve=>setTimeout(resolve,0))}
function applyFilters(){const token=++scanVersion;page=0;full=false;const term=search.value.toLowerCase(),selectedCategory=category.value;if(!term&&!selectedCategory){matches=null;scanning=false;render();return}scanning=true;document.getElementById('body').textContent='';document.getElementById('count').textContent='正在搜尋完整離線清單…';(async()=>{const found=[];for(let index=0;index<Math.ceil(total/chunkSize);index++){if(token!==scanVersion)return;const rows=chunkRows(index);for(let offset=0;offset<rows.length;offset++){const row=rows[offset],rowCategory=row.Category||'Fleet';if(selectedCategory&&rowCategory!==selectedCategory)continue;let matched=false;for(const value of Object.values(row)){if(String(value).toLowerCase().includes(term)){matched=true;break}}if(matched)found.push(index*chunkSize+offset)}await yieldTurn()}if(token!==scanVersion)return;matches=found;scanning=false;render()})()}
search.oninput=category.onchange=applyFilters;document.getElementById('prev').onclick=()=>{if(scanning)return;page=Math.max(0,page-1);full=false;render()};document.getElementById('next').onclick=()=>{if(scanning)return;page++;full=false;render()};document.getElementById('all').onclick=()=>{if(scanning){window.alert('搜尋仍在進行，完成後再列印。');return}if(matchCount()>2000){window.alert('符合項目超過 2,000 筆，請縮小搜尋範圍。完整清單仍保留在離線報告與同名文字檔。');return}full=true;render();window.print()};render();
</script></html>
'@
    $fullPath=[IO.Path]::GetFullPath($Path);$directory=[IO.Path]::GetDirectoryName($fullPath);if(-not [IO.Directory]::Exists($directory)){[void][IO.Directory]::CreateDirectory($directory)}
    $writer=New-Object IO.StreamWriter($fullPath,$false,(New-Object Text.UTF8Encoding($false)))
    try{
        $parts=[regex]::Split($template,'__TITLE__|__META__|__SUMMARY__|__LINKS__|__CHUNKS__');$markers=[regex]::Matches($template,'__TITLE__|__META__|__SUMMARY__|__LINKS__|__CHUNKS__');for($i=0;$i -lt $parts.Count;$i++){$writer.Write($parts[$i]);if($i -lt $markers.Count){switch($markers[$i].Value){'__TITLE__'{$writer.Write($safeTitle)}'__META__'{$writer.Write($metadataJson)}'__SUMMARY__'{$writer.Write($summaryJson)}'__LINKS__'{$writer.Write($ReviewLinks)}'__CHUNKS__'{for($offset=0;$offset -lt $count;$offset+=$chunkSize){$index=[int]($offset/$chunkSize);$length=[Math]::Min($chunkSize,$count-$offset);$chunk=New-Object 'System.Collections.Generic.List[object]';for($rowIndex=$offset;$rowIndex -lt ($offset+$length);$rowIndex++){$chunk.Add($allRows[$rowIndex])};$json=ConvertTo-Json -InputObject $chunk.ToArray() -Depth 8 -Compress;$json=$json.Replace('<','\u003c').Replace('>','\u003e').Replace('&','\u0026');$writer.Write('<script type="application/json" id="chunk-');$writer.Write($index);$writer.Write('">');$writer.Write($json);$writer.Write('</script>')}}}}}
    }finally{$writer.Dispose()}
}
function Get-WsmSafeSpecSummary($Item) {
    if(-not $Item.PSObject.Properties['MigrationSpec'] -or -not $Item.MigrationSpec){return 'Migration specification required'}
    $s=$Item.MigrationSpec;$safe=[ordered]@{Adapter=$s.Adapter;SpecSHA256=(Get-WsmHashText ($s | ConvertTo-Json -Depth 40 -Compress))}
    foreach($key in @('SourcePath','TargetPath','ExcludedRelativePaths','Consistency','Metadata','ConflictPolicy','AclControlPolicy','CatchUpPolicy','DesiredFinalState','BusinessChecks','AccountMode','ConfigFiles','ConfigOverrides')){if($s.PSObject.Properties[$key]){$safe[$key]=$s.$key}}
    if($s.PSObject.Properties['Desired']){$safe.DesiredSHA256=Get-WsmHashText ($s.Desired | ConvertTo-Json -Depth 40 -Compress)}
    if($s.Adapter -ceq 'SmbShare' -and $s.PSObject.Properties['Desired'] -and $s.Desired.PSObject.Properties['DrainPolicy']){$safe.ShareDrainPolicy=$s.Desired.DrainPolicy}
    if($s.Adapter -ceq 'WindowsFeature' -and $s.PSObject.Properties['Desired'] -and $s.Desired.PSObject.Properties['SideEffects']){$safe.InstallerConsumers=@($s.Desired.SideEffects | Select-Object Kind,Name,FinalMode,FinalRunning,CatchUpPolicy);$safe.InstallerIsolationReviewRequired=$true}
    if($s.Adapter -ceq 'Service' -and $s.PSObject.Properties['Desired'] -and $s.Desired.PSObject.Properties['Supplement']){$supp=$s.Desired.Supplement;try{[void](Assert-WsmServiceSupplement $supp);$safe.ServicePolicy=[pscustomobject]@{ServiceType=$supp.ServiceType;DelayedAutoStart=$supp.DelayedAutoStart;ServiceSidType=$supp.ServiceSidType;RequiredPrivilegeCount=@($supp.RequiredPrivileges).Count;EnvironmentCount=@($supp.Environment).Count;TriggerCount=@($supp.Triggers).Count;FailureActionTypes=@($supp.FailureActions.Actions | ForEach-Object Type);SupplementSHA256=(Get-WsmHashText ($supp | ConvertTo-Json -Depth 40 -Compress))}}catch{$safe.ServicePolicy='Incomplete service supplement; review required'}}
    if($s.PSObject.Properties['RemoteStorage']){try{$safe.RemoteStorage=@(Get-WsmRemoteStorageSummary @([pscustomobject]@{ItemId=$Item.ItemId;Decision='Include';MigrationSpec=$s}))}catch{$safe.RemoteStorage='Invalid remote storage contract; review required'}}
    ConvertTo-Json -InputObject $safe -Depth 12 -Compress
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
            $decisionRows=@($rows | Where-Object {$_.PSObject.Properties['Decision'] -and [string]$_.Decision -in @('Include','Exclude','Pending')})
            if($decisionRows.Count){$writer.WriteLine(('=== {0}: {1} | Include {2} | Exclude {3} | Pending {4} | N/A {5} ===' -f $category,$rows.Count,@($decisionRows | Where-Object Decision -CEQ Include).Count,@($decisionRows | Where-Object Decision -CEQ Exclude).Count,@($decisionRows | Where-Object Decision -CEQ Pending).Count,($rows.Count-$decisionRows.Count)))}
            else{$writer.WriteLine(('=== {0}: {1} | Include N/A | Exclude N/A | Pending N/A | N/A {1} ===' -f $category,$rows.Count))}
            foreach ($i in $rows) { $writer.WriteLine(('{0} | {1} | {2} | {3} | {4}' -f $i.ItemId,$i.Kind,$i.Status,$i.Decision,$i.Name)); $writer.WriteLine(('Reason: {0} / Rule: {1} / Owner: {2} / Evidence: {3}' -f $i.Reason,$i.RuleId,$i.Owner,$i.Evidence)); $writer.WriteLine(('Path: {0} / Account: {1} / Endpoint: {2} / Group: {3}' -f $i.Mapping,$i.AccountMapping,$i.EndpointMapping,$i.ApplicationGroup));$writer.WriteLine(('Reviewed migration spec: '+(Get-WsmSafeSpecSummary $i))); foreach ($d in $i.Dependencies) { $writer.WriteLine(('Dependency: {0} / {1}' -f $d.ItemId,$d.Type)) } }
        }
    } finally { $writer.Dispose() }
}
function Export-WsmReport {
    param([string]$Workspace,[string]$PairId,[string]$Path)
    $c=Get-WsmCatalog $Workspace $PairId
    $rows=@($c.Items | Sort-Object Category,Name,ItemId | Select-Object Category,Kind,Name,ItemId,Status,Present,Decision,Reason,Mapping,AccountMapping,EndpointMapping,ApplicationGroup,BuiltIn,RuleId,Owner,Evidence,ConsistencyGroup,@{n='ReviewedSpec';e={Get-WsmSafeSpecSummary $_}},@{n='Dependencies';e={ @($_.Dependencies | ForEach-Object { $_.Type+':'+$_.ItemId }) -join '; ' }},@{n='Restoration';e={if($_.PSObject.Properties['MigrationSpec'] -and $_.MigrationSpec){$_.MigrationSpec.Adapter+' / IsolatedPilot; production unverified'}else{'Migration specification required'}}})
    $approval='NotApproved'; if ($c.Approval) { $approval=$c.Approval.ApprovalId }
    Export-WsmTextReport $Workspace $PairId ($Path+'.txt')
    $raw=[Uri]([IO.Path]::GetFullPath((Get-WsmCatalogPath $Workspace $PairId)))
    $links='<p>完整分類文字清單：'+[Net.WebUtility]::HtmlEncode([IO.Path]::GetFileName($Path+'.txt'))+'。敏感原始證據（限有權限人員）：<a href="'+[Net.WebUtility]::HtmlEncode($raw.AbsoluteUri)+'">受控 catalog JSON</a>；請勿轉寄原始設定。</p>'
    Write-WsmHtml $Path ($c.Source.Name+' -> '+$c.TargetName+' / batch '+$c.BatchId+' / pair '+$PairId+' / inventory '+$c.InventoryRevision+' / review '+$c.DecisionRevision+' / approval '+$approval+' / generation NotStarted / received '+$c.ImportedUtc+' / generated '+(Get-WsmUtc)) $rows -ReviewLinks $links
}
function Export-WsmFleetReport {
    param([string]$Workspace,[string]$Path,[ValidateRange(1,720)][int]$StaleAfterHours=24)
    $f=Get-WsmFleet $Workspace
    $rows=@(foreach ($p in $f.Pairs) {
        $c=Get-WsmCatalog $Workspace $p.PairId
        $age=([DateTime]::UtcNow-[DateTime]::Parse($c.ImportedUtc).ToUniversalTime()).TotalHours
        $owner=''; $wave=''; if ($c.PSObject.Properties['PairPlan']) { $owner=$c.PairPlan.Owner; $wave=$c.PairPlan.Wave }
        $stage='Inventory'; $status='Received'; if ($c.PSObject.Properties['StageResults'] -and $c.StageResults.Count) { $r=Get-WsmLatestStageResult $c; $stage=$r.Stage; $status=$r.Status; if (-not (Test-WsmStageResultCurrent $c $r)) { $status='StaleEvidence' } }
        $evidenceAge=$age;if($c.PSObject.Properties['EvidenceUtc']){$evidenceAge=([DateTime]::UtcNow-[DateTime]::Parse($c.EvidenceUtc).ToUniversalTime()).TotalHours};$stageAge=$null;if($c.PSObject.Properties['StageResults'] -and $c.StageResults.Count){$lastResult=Get-WsmLatestStageResult $c;$stageAge=([DateTime]::UtcNow-[DateTime]::Parse($lastResult.ProducedUtc).ToUniversalTime()).TotalHours}
        $edges=''; if ($c.PSObject.Properties['CrossHostDependencies']) { $edges=@($c.CrossHostDependencies | ForEach-Object { $_.Type+':'+$_.PairId }) -join '; ' }
        [pscustomobject][ordered]@{ Source=$c.Source.Name; Target=$c.TargetName; PairId=$p.PairId; ReceivedUtc=$c.ImportedUtc; AgeHours=[math]::Round($age,1); EvidenceAgeHours=[Math]::Round($evidenceAge,1);StageAgeHours=$stageAge;StageStale=($null -ne $stageAge -and $stageAge -gt $StaleAfterHours);Stale=($age -gt $StaleAfterHours -or $evidenceAge -gt $StaleAfterHours); ClockSkew=($age -lt -0.0833 -or $evidenceAge -lt -0.0833); Owner=$owner; Wave=$wave; Stage=$stage; Status=$status; StageSummary=(Get-WsmStageResultSummary $c); CrossHostDependencies=$edges; InventoryRevision=$c.InventoryRevision; DecisionRevision=$c.DecisionRevision; Total=@($c.Items).Count; Pending=@($c.Items | Where-Object Decision -EQ Pending).Count; Included=@($c.Items | Where-Object Decision -EQ Include).Count; Excluded=@($c.Items | Where-Object Decision -EQ Exclude).Count; ReviewApproved=($null -ne $c.Approval); PilotPlanApproved=($c.Approval -and $c.Approval.PSObject.Properties['Kind'] -and $c.Approval.Kind -eq 'MigrationPlan');ExportReady=$false; RestoreSupported=$false; NextStep='Complete review / validate role-specific adapters' }
    })
    Write-WsmHtml $Path ('Fleet '+$f.BatchId+' / generated '+(Get-WsmUtc)) $rows
}
