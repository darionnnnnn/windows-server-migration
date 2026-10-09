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
search.oninput=category.onchange=applyFilters;document.getElementById('prev').onclick=()=>{if(scanning)return;page=Math.max(0,page-1);full=false;render()};document.getElementById('next').onclick=()=>{if(scanning)return;page++;full=false;render()};document.getElementById('all').onclick=()=>{if(scanning){window.alert('搜尋仍在進行，完成後再列印。');return}full=true;render();window.print()};render();
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
function ConvertTo-WsmReportSafeText($Value) {
    if($null -eq $Value){return ''}
    $text=[string]$Value
    $text=[regex]::Replace($text,'(?i)(password|passwd|pwd|secret|token|credential|client_secret|wallet)\s*[:=]\s*([^;\s,]+)','${1}=[REDACTED]')
    $text=[regex]::Replace($text,'(?i)(://)[^/@\s:]+:[^/@\s]+@','$1[REDACTED]@')
    if($text.Length -gt 8192){$text=$text.Substring(0,8192)+'…[bounded]'}
    $text
}
function ConvertTo-WsmReportCsvValue($Value) {
    $text=ConvertTo-WsmReportSafeText $Value
    if($text -match '^\s*[=+@-]' -or $text -match '^[\t\r\n]'){$text="'$text"}
    '"'+$text.Replace('"','""')+'"'
}
function Get-WsmReportValue($Object,[string]$Name,$Default='') {
    if($null -eq $Object){return $Default}
    if($Object -is [Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]};return $Default}
    $property=$Object.PSObject.Properties[$Name];if($property){return $property.Value};$Default
}
function Get-WsmReportSafeContext($Context) {
    $safe=[ordered]@{}
    foreach($name in @('RuntimeAccount','AccountType','AccountName','AccountSid','ServiceName','Provider','Version','Architecture','OracleHome','ObservedEffectivePath','ConsumerItemIds')){
        $value=Get-WsmReportValue $Context $name $null
        if($null -ne $value){if($name -eq 'ConsumerItemIds'){$safe[$name]=@($value | ForEach-Object {ConvertTo-WsmReportSafeText $_})}else{$safe[$name]=ConvertTo-WsmReportSafeText $value}}
    }
    $proof=Get-WsmReportValue $Context 'PreparationEvidence' $null
    if($proof){
        $mediaHash=[string](Get-WsmReportValue $proof 'MediaSHA256' '');if($mediaHash -notmatch '^[a-fA-F0-9]{64}$'){$mediaHash=''}
        $isolationHash=[string](Get-WsmReportValue $proof 'IsolationEvidenceSHA256' '');if($isolationHash -notmatch '^[a-fA-F0-9]{64}$'){$isolationHash=''}
        $verification=[string](Get-WsmReportValue $proof 'VerificationMethod' 'NotTested');if($verification -notin @('SignatureVerified','OwnerVerified')){$verification='NotTested'}
        $restart=[string](Get-WsmReportValue $proof 'RestartStatus' 'NotTested');if($restart -notin @('CompletedAndVerified','NotRequired')){$restart='NotTested'}
        $order=Get-WsmReportValue $proof 'InstallOrder' 'Unknown';$orderNumber=[int]0;if(-not [int]::TryParse([string]$order,[ref]$orderNumber) -or $orderNumber -lt 1){$order='Unknown'}else{$order=$orderNumber}
        $safe.PreparationEvidence=[pscustomobject][ordered]@{MediaReference=ConvertTo-WsmReportSafeText (Get-WsmReportValue $proof 'MediaReference' '');MediaSHA256=$mediaHash;VerificationMethod=$verification;SignatureEvidence=ConvertTo-WsmReportSafeText (Get-WsmReportValue $proof 'SignatureEvidence' '');VendorOSSupportReference=ConvertTo-WsmReportSafeText (Get-WsmReportValue $proof 'VendorOSSupportReference' '');VendorSupportCheckedUtc=ConvertTo-WsmReportSafeText (Get-WsmReportValue $proof 'VendorSupportCheckedUtc' '');LicenseReference=ConvertTo-WsmReportSafeText (Get-WsmReportValue $proof 'LicenseReference' '');InstallOrder=$order;IsolationEvidenceSHA256=$isolationHash;RestartStatus=$restart;SideEffectsReference=ConvertTo-WsmReportSafeText (Get-WsmReportValue $proof 'SideEffectsReference' '')}
    }
    [pscustomobject]$safe
}
function Get-WsmReportSoftwareProjection($Catalog) {
    $source=if($Catalog.PSObject.Properties['SoftwareCatalog']){$Catalog.SoftwareCatalog}else{$null}
    $general=if($Catalog.PSObject.Properties['GeneralHost']){$Catalog.GeneralHost}else{$null}
    $reviewed=$null;if($general -and $general.PSObject.Properties['SoftwareCatalog']){$reviewed=$general.SoftwareCatalog}
    $softwareCatalog=$source;$authority='SourceInventoryFallback';$sourceCount=0
    if($source){$sourceCount=@($source.Entries).Count}
    if($null -ne $reviewed){$softwareCatalog=$reviewed;$authority='GeneralHost'}
    $software=@();$coverage=@();$preparation=@();$requirements=@();$receipts=@()
    if($softwareCatalog){
        Assert-WsmSoftwareCatalog $softwareCatalog | Out-Null
        $decisionIndex=@{}
        if($general){foreach($decision in @($general.SoftwareDecisions)){$decisionKey=[string]$decision.SoftwareId;if(-not $decisionIndex.ContainsKey($decisionKey)){$decisionIndex[$decisionKey]=New-Object 'System.Collections.Generic.List[object]'};$decisionIndex[$decisionKey].Add($decision)}}
        $software=@(for($entryIndex=0;$entryIndex -lt @($softwareCatalog.Entries).Count;$entryIndex++){
            $entry=$softwareCatalog.Entries[$entryIndex];$decision=@();if($decisionIndex.ContainsKey([string]$entry.SoftwareId)){$decision=$decisionIndex[[string]$entry.SoftwareId].ToArray()}
            [pscustomobject][ordered]@{Section='Software';SoftwareId=$entry.SoftwareId;Name=ConvertTo-WsmReportSafeText $entry.Name;Version=ConvertTo-WsmReportSafeText $entry.Version;Publisher=ConvertTo-WsmReportSafeText $entry.Publisher;Architecture=$entry.Architecture;Scope=$entry.Scope;SID=$entry.SID;RegistryView=$entry.RegistryView;Location=ConvertTo-WsmReportSafeText $entry.Location;SourceKind=$entry.SourceKind;CaptureStatus=$entry.CaptureStatus;ItemIds=(@($entry.ItemIds) -join ', ');ManualEntry=($entry.SourceKind -eq 'OwnerProvided');Handling=$(if($decision.Count -eq 1){$decision[0].Disposition}else{'Unknown'});Owner=$(if($decision.Count -eq 1){ConvertTo-WsmReportSafeText $decision[0].Owner}else{ConvertTo-WsmReportSafeText (Get-WsmReportValue $entry 'Owner' '')});EvidencePointer=('SoftwareCatalog#/Entries/'+$entryIndex);TargetStatus='NotTested'}
        })
        $coverage=@(foreach($row in $softwareCatalog.Coverage){[pscustomobject][ordered]@{Section='Coverage';Probe=$row.Probe;Scope=$row.Scope;SID=$row.SID;View=$row.View;Status=$row.Status;Count=$row.Count;ErrorKind=$row.ErrorKind;ObservedUtc=$row.ObservedUtc;EvidenceKind=$row.EvidenceKind;EvidencePointer='SoftwareCatalog#/Coverage'}})
        $preparation=@(foreach($row in $softwareCatalog.PreparationRequirements){[pscustomobject][ordered]@{Section='Preparation';PreparationId=$row.PreparationId;SoftwareId=$row.SoftwareId;Status=$row.Status;RequiredPhase=$row.RequiredPhase;ConsumerItemIds=(@($row.ConsumerItemIds) -join ', ');Owner=ConvertTo-WsmReportSafeText $row.Owner;Reason=ConvertTo-WsmReportSafeText $row.Reason}})
        if($general){
            $requirements=@(foreach($r in $general.Requirements){[pscustomobject][ordered]@{Section='Requirement';RequirementId=$r.RequirementId;Type=$r.Type;ProviderSoftwareId=$r.ProviderSoftwareId;ProviderItemId=$r.ProviderItemId;ConsumerItemIds=(@($r.ConsumerItemIds) -join ', ');Certainty=$r.Certainty;RequiredPhase=$r.RequiredPhase;ExpectedVersion=ConvertTo-WsmReportSafeText $r.ExpectedVersion;Architecture=$r.Architecture;Context=Get-WsmReportSafeContext $r.Context;Owner=ConvertTo-WsmReportSafeText $r.Owner;Decision=$r.Decision;DecisionReason=ConvertTo-WsmReportSafeText $r.DecisionReason;Status='Requires current phase evidence'}})
            $receipts=@(foreach($r in $general.EvidenceReceipts){[pscustomobject][ordered]@{Section='Receipt';ReceiptId=$r.ReceiptId;RequirementIds=(@($r.RequirementIds) -join ', ');Phase=$r.Phase;TargetFingerprint=$r.TargetFingerprint;Context=Get-WsmReportSafeContext $r.Context;ObservedUtc=$r.ObservedUtc;ExpiresUtc=$r.ExpiresUtc;EvidenceKind=$r.EvidenceKind;EvidencePathHash=$r.EvidencePathHash;Owner=ConvertTo-WsmReportSafeText $r.Owner;Status='Stored receipt; phase/context/fingerprint/expiry must still be validated'}})
        }
    } else {$coverage=@([pscustomobject][ordered]@{Section='Coverage';Probe='SoftwareCatalog';Scope='All';SID='';View='';Status='NotTested';Count=0;ErrorKind='SourceSoftwareCaptureMissing';ObservedUtc='';EvidenceKind='';EvidencePointer='';NextStep='Capture software on source host; missing catalog is not proof of absence'})}
    [pscustomobject][ordered]@{Authority=$authority;SourceSoftwareCount=$sourceCount;AuthoritativeSoftwareCount=@($software).Count;Software=$software;Coverage=$coverage;PreparationRequirements=$preparation;Requirements=$requirements;EvidenceReceipts=$receipts;ReadinessStatus='NotTested';ProductionQualified=$false}
}
function Get-WsmReportRows($Catalog,$SoftwareProjection) {
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($item in @($Catalog.Items | Sort-Object Category,Name,ItemId)){
        $adapter='';$specHash='';if($item.PSObject.Properties['MigrationSpec'] -and $item.MigrationSpec){$adapter=[string](Get-WsmReportValue $item.MigrationSpec 'Adapter' '');$specHash=Get-WsmHashText (ConvertTo-Json -InputObject $item.MigrationSpec -Depth 40 -Compress)}
        $rows.Add([pscustomobject][ordered]@{Section='InventoryItem';Category=$item.Category;Kind=$item.Kind;Name=ConvertTo-WsmReportSafeText $item.Name;ItemId=$item.ItemId;Status=$item.Status;Present=$(if($item.PSObject.Properties['Present']){$item.Present}else{$true});Decision=$item.Decision;Reason=ConvertTo-WsmReportSafeText $item.Reason;Mapping=ConvertTo-WsmReportSafeText $item.Mapping;AccountMapping=ConvertTo-WsmReportSafeText $item.AccountMapping;EndpointMapping=ConvertTo-WsmReportSafeText $item.EndpointMapping;ApplicationGroup=ConvertTo-WsmReportSafeText $item.ApplicationGroup;BuiltIn=$item.BuiltIn;RuleId=$item.RuleId;Owner=ConvertTo-WsmReportSafeText $item.Owner;EvidenceSHA256=$(if($item.Evidence){Get-WsmHashText ([string]$item.Evidence)}else{''});ConsistencyGroup=ConvertTo-WsmReportSafeText $item.ConsistencyGroup;Adapter=$adapter;MigrationSpecSHA256=$specHash;Dependencies=(@($item.Dependencies | ForEach-Object {$_.Type+':'+$_.ItemId}) -join '; ');Restoration=$(if($adapter){$adapter+' / isolated pilot; production unverified'}else{'Migration specification required'})})
    }
    foreach($section in @('Software','Coverage','PreparationRequirements','Requirements','EvidenceReceipts')){foreach($row in @($SoftwareProjection.$section)){$rows.Add($row)}}
    $rows.ToArray()
}
function Export-WsmTextReport {
    param([string]$Workspace,[string]$PairId,[string]$Path)
    $c=Get-WsmCatalog $Workspace $PairId;$bundle=Get-WsmReportSoftwareProjection $c
    $writer=New-Object IO.StreamWriter([IO.Path]::GetFullPath($Path),$false,(New-Object Text.UTF8Encoding($false)))
    try {
        $writer.WriteLine(('Batch {0} / Pair {1} / Inventory {2} / Decision {3}' -f $c.BatchId,$PairId,$c.InventoryRevision,$c.DecisionRevision))
        $writer.WriteLine(('Software catalog authority: {0}; source entries {1}; current entries {2}; coverage rows {3}; ProductionQualified=false' -f $bundle.Authority,$bundle.SourceSoftwareCount,$bundle.AuthoritativeSoftwareCount,$bundle.Coverage.Count))
        $writer.WriteLine('Complete offline review; not proof of restoration or readiness. Raw settings, commands, DSN credentials and full connection strings are omitted.')
        foreach ($category in $script:Categories) {
            $rows=@($c.Items | Where-Object Category -CEQ $category | Sort-Object Name,ItemId)
            $decisionRows=@($rows | Where-Object {$_.PSObject.Properties['Decision'] -and [string]$_.Decision -in @('Include','Exclude','Pending')})
            if($decisionRows.Count){$writer.WriteLine(('=== {0}: {1} | Include {2} | Exclude {3} | Pending {4} | N/A {5} ===' -f $category,$rows.Count,@($decisionRows | Where-Object Decision -CEQ Include).Count,@($decisionRows | Where-Object Decision -CEQ Exclude).Count,@($decisionRows | Where-Object Decision -CEQ Pending).Count,($rows.Count-$decisionRows.Count)))}
            else{$writer.WriteLine(('=== {0}: {1} | Include N/A | Exclude N/A | Pending N/A | N/A {1} ===' -f $category,$rows.Count))}
            foreach ($i in $rows) { $writer.WriteLine(('{0} | {1} | {2} | {3} | {4}' -f $i.ItemId,$i.Kind,$i.Status,$i.Decision,(ConvertTo-WsmReportSafeText $i.Name))); $writer.WriteLine(('Reason: {0} / Rule: {1} / Owner: {2} / EvidenceSHA256: {3}' -f (ConvertTo-WsmReportSafeText $i.Reason),$i.RuleId,(ConvertTo-WsmReportSafeText $i.Owner),$(if($i.Evidence){Get-WsmHashText ([string]$i.Evidence)}else{''}))); foreach ($d in $i.Dependencies) { $writer.WriteLine(('Dependency: {0} / {1}' -f $d.ItemId,$d.Type)) } }
        }
        foreach($sectionName in @('Software','Coverage','PreparationRequirements','Requirements','EvidenceReceipts')){$rows=@($bundle.$sectionName);$writer.WriteLine();$writer.WriteLine(('=== {0}: {1} ===' -f $sectionName,$rows.Count));foreach($row in $rows){$pairs=@(foreach($prop in $row.PSObject.Properties){$value=ConvertTo-WsmReportSafeText (ConvertTo-Json -InputObject $prop.Value -Depth 8 -Compress);('{0}: {1}' -f $prop.Name,$value)});$writer.WriteLine(($pairs -join ' | '))}}
        $writer.WriteLine();$writer.WriteLine('=== Readiness ===');$writer.WriteLine('NotTested: no target observation and phase evidence were supplied. This report does not grant readiness.')
    } finally { $writer.Dispose() }
}
function Export-WsmReport {
    param([string]$Workspace,[string]$PairId,[string]$Path)
    $c=Get-WsmCatalog $Workspace $PairId;$bundle=Get-WsmReportSoftwareProjection $c
    $rows=@(Get-WsmReportRows $c $bundle)
    $approval='NotApproved'; if ($c.Approval) { $approval=$c.Approval.ApprovalId }
    Export-WsmTextReport $Workspace $PairId ($Path+'.txt')
    $title=$c.Source.Name+' -> '+$c.TargetName+' / batch '+$c.BatchId+' / pair '+$PairId+' / inventory '+$c.InventoryRevision+' / review '+$c.DecisionRevision+' / approval '+$approval+' / generation NotStarted / received '+$c.ImportedUtc+' / generated '+(Get-WsmUtc)
    Write-WsmHtml $Path $title $rows
    $safeDocument=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='CatalogReportProjection';PairId=$PairId;InventoryRevision=$c.InventoryRevision;DecisionRevision=$c.DecisionRevision;GeneratedUtc=Get-WsmUtc;InventoryItems=@($rows | Where-Object Section -EQ InventoryItem);SoftwareAuthority=$bundle.Authority;SourceSoftwareCount=$bundle.SourceSoftwareCount;AuthoritativeSoftwareCount=$bundle.AuthoritativeSoftwareCount;Software=@($bundle.Software);Coverage=@($bundle.Coverage);PreparationRequirements=@($bundle.PreparationRequirements);Requirements=@($bundle.Requirements);EvidenceReceipts=@($bundle.EvidenceReceipts);ReadinessStatus='NotTested';ProductionQualified=$false;Counts=[pscustomobject]@{InventoryItems=@($rows | Where-Object Section -EQ InventoryItem).Count;Software=@($bundle.Software).Count;Coverage=@($bundle.Coverage).Count;PreparationRequirements=@($bundle.PreparationRequirements).Count;Requirements=@($bundle.Requirements).Count;EvidenceReceipts=@($bundle.EvidenceReceipts).Count;AllRows=$rows.Count}}
    $jsonPath=$Path+'.json';$csvPath=$Path+'.csv'
    Assert-WsmNoReparse $jsonPath;Assert-WsmNoReparse $csvPath
    if([IO.File]::Exists($jsonPath) -or [IO.File]::Exists($csvPath)){throw 'Catalog report sidecar already exists; reports are immutable, choose a new output name.'}
    Write-WsmJson $jsonPath $safeDocument
    $headers=New-Object 'System.Collections.Generic.List[string]';foreach($row in $rows){foreach($property in $row.PSObject.Properties){if(-not $headers.Contains($property.Name)){$headers.Add($property.Name)}}}
    $writer=New-Object IO.StreamWriter([IO.Path]::GetFullPath($csvPath),$false,(New-Object Text.UTF8Encoding($false)))
    try{$writer.WriteLine((@($headers | ForEach-Object {ConvertTo-WsmReportCsvValue $_}) -join ','));foreach($row in $rows){$writer.WriteLine((@($headers | ForEach-Object {ConvertTo-WsmReportCsvValue (Get-WsmReportValue $row $_ '')}) -join ','))}}finally{$writer.Dispose()}
    [pscustomobject][ordered]@{HtmlPath=[IO.Path]::GetFullPath($Path);TextPath=[IO.Path]::GetFullPath($Path+'.txt');JsonPath=[IO.Path]::GetFullPath($jsonPath);CsvPath=[IO.Path]::GetFullPath($csvPath);Counts=$safeDocument.Counts;ProductionQualified=$false}
}
function Export-WsmFleetReport {
    param([string]$Workspace,[string]$Path,[ValidateRange(1,720)][int]$StaleAfterHours=24)
    $f=Get-WsmFleet $Workspace
    $rows=@(foreach ($p in $f.Pairs) {
        $c=Get-WsmCatalog $Workspace $p.PairId
        $confirmationDocuments=@();$confirmationStatus='NotAvailable';$confirmationLatest=''
        if(Get-Command Get-WsmEnvironmentConfirmationReferences -ErrorAction SilentlyContinue){
            try{
                $confirmationReferences=Get-WsmEnvironmentConfirmationReferences -Workspace $Workspace -PairId $p.PairId
                $confirmationDocuments=@(foreach($document in @($confirmationReferences.Documents)){
                    [pscustomobject][ordered]@{DocumentId=$document.DocumentId;PairId=$document.PairId;InventoryRevision=$document.InventoryRevision;DecisionRevision=$document.DecisionRevision;TargetObservationRevision=$document.TargetObservationRevision;TargetObservationHash=$document.TargetObservationHash;TargetObservationStatus=$document.TargetObservationStatus;SourceInventoryProjectionHash=$document.SourceInventoryProjectionHash;ReportProjectionHash=$document.ReportProjectionHash;GeneratedUtc=$document.GeneratedUtc;Paths=$document.Paths;Hashes=$document.Hashes;AuthoritativeApproval=$false;ReadinessProof=$false}
                })
                $confirmationLatest=[string]$confirmationReferences.LatestDocumentId
                $confirmationStatus=$(if($confirmationDocuments.Count){'LocatorOnly'}else{'NoDocuments'})
            }catch{$confirmationStatus='IndexValidationFailed'}
        }
        $age=([DateTime]::UtcNow-[DateTime]::Parse($c.ImportedUtc).ToUniversalTime()).TotalHours
        $deliverySummary=[pscustomobject]@{Status='NoReceipt';Mode='';Generation=0;VolumeCount=0;TotalVolumeBytes=0;TransportHash='';DeliveryId='';ReportOnly=$true;ReadinessProof=$false;ProductionVerified=$false}
        if(Get-Command Get-WsmFleetDeliverySummary -ErrorAction SilentlyContinue){try{$deliverySummary=Get-WsmFleetDeliverySummary $c}catch{$deliverySummary.Status='ReceiptValidationFailed'}}
        $owner=''; $wave=''; if ($c.PSObject.Properties['PairPlan']) { $owner=$c.PairPlan.Owner; $wave=$c.PairPlan.Wave }
        $stage='Inventory'; $status='Received'; if ($c.PSObject.Properties['StageResults'] -and $c.StageResults.Count) { $r=Get-WsmLatestStageResult $c; $stage=$r.Stage; $status=$r.Status; if (-not (Test-WsmStageResultCurrent $c $r)) { $status='StaleEvidence' } }
        $evidenceAge=$age;if($c.PSObject.Properties['EvidenceUtc']){$evidenceAge=([DateTime]::UtcNow-[DateTime]::Parse($c.EvidenceUtc).ToUniversalTime()).TotalHours};$stageAge=$null;if($c.PSObject.Properties['StageResults'] -and $c.StageResults.Count){$lastResult=Get-WsmLatestStageResult $c;$stageAge=([DateTime]::UtcNow-[DateTime]::Parse($lastResult.ProducedUtc).ToUniversalTime()).TotalHours}
        $edges=''; if ($c.PSObject.Properties['CrossHostDependencies']) { $edges=@($c.CrossHostDependencies | ForEach-Object { $_.Type+':'+$_.PairId }) -join '; ' }
        [pscustomobject][ordered]@{ Source=$c.Source.Name; Target=$c.TargetName; PairId=$p.PairId; ReceivedUtc=$c.ImportedUtc; AgeHours=[math]::Round($age,1); EvidenceAgeHours=[Math]::Round($evidenceAge,1);StageAgeHours=$stageAge;StageStale=($null -ne $stageAge -and $stageAge -gt $StaleAfterHours);Stale=($age -gt $StaleAfterHours -or $evidenceAge -gt $StaleAfterHours); ClockSkew=($age -lt -0.0833 -or $evidenceAge -lt -0.0833); Owner=$owner; Wave=$wave; Stage=$stage; Status=$status; StageSummary=(Get-WsmStageResultSummary $c); CrossHostDependencies=$edges; InventoryRevision=$c.InventoryRevision; DecisionRevision=$c.DecisionRevision; Total=@($c.Items).Count; Pending=@($c.Items | Where-Object Decision -EQ Pending).Count; Included=@($c.Items | Where-Object Decision -EQ Include).Count; Excluded=@($c.Items | Where-Object Decision -EQ Exclude).Count; ReviewApproved=($null -ne $c.Approval); PilotPlanApproved=($c.Approval -and $c.Approval.PSObject.Properties['Kind'] -and $c.Approval.Kind -eq 'MigrationPlan');EnvironmentConfirmationStatus=$confirmationStatus;EnvironmentConfirmationCount=$confirmationDocuments.Count;LatestEnvironmentConfirmationDocumentId=$confirmationLatest;EnvironmentConfirmationDocuments=$confirmationDocuments;EnvironmentConfirmationAuthoritativeApproval=$false;EnvironmentConfirmationReadinessProof=$false;DeliveryStatus=$deliverySummary.Status;DeliveryMode=$deliverySummary.Mode;DeliveryGeneration=$deliverySummary.Generation;DeliveryVolumeCount=$deliverySummary.VolumeCount;DeliveryTotalVolumeBytes=$deliverySummary.TotalVolumeBytes;DeliveryTransportHash=$deliverySummary.TransportHash;DeliveryId=$deliverySummary.DeliveryId;DeliveryReportOnly=$true;DeliveryReadinessProof=$false;DeliveryProductionVerified=$false;ExportReady=$false; RestoreSupported=$false; NextStep='Complete review / validate role-specific adapters' }
    })
    Write-WsmHtml $Path ('Fleet '+$f.BatchId+' / generated '+(Get-WsmUtc)) $rows
}
