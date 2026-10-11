#requires -Version 5.1
param([string]$ProjectRoot=([IO.Path]::GetDirectoryName($PSScriptRoot)))
$ErrorActionPreference='Stop'
$script:ProjectRoot=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
$script:OutputRoot=Join-Path $script:ProjectRoot 'docs\html'
$script:IncludedSources=@{}
function Encode([string]$Value){[Net.WebUtility]::HtmlEncode($Value)}
function Test-WithinRoot([string]$Path){
    $full=[IO.Path]::GetFullPath($Path)
    $prefix=$script:ProjectRoot+[IO.Path]::DirectorySeparatorChar
    $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)
}
function Get-OutputRelativePath([string]$Path){
    $basePath=[IO.Path]::GetFullPath($script:OutputRoot)+[IO.Path]::DirectorySeparatorChar
    $baseUri=New-Object Uri($basePath)
    $targetUri=New-Object Uri([IO.Path]::GetFullPath($Path))
    $baseUri.MakeRelativeUri($targetUri).ToString()
}
function Resolve-DocumentationLink([string]$RawTarget,[string]$SourcePath){
    $target=[Net.WebUtility]::HtmlDecode($RawTarget).Trim().Trim('<','>')
    if($target -match '[\x00-\x20\x7f]' -or $target -match '^//'){return $null}
    if($target -match '^(?i:https?)://'){
        $uri=$null
        if([Uri]::TryCreate($target,[UriKind]::Absolute,[ref]$uri) -and $uri.Scheme -in @('http','https')){return $uri.AbsoluteUri}
        return $null
    }
    if($target -match '^[A-Za-z][A-Za-z0-9+.-]*:'){return $null}
    if($target.StartsWith('#')){return $target}
    $decoded=[Uri]::UnescapeDataString($target)
    if($decoded -match '[\x00-\x1f]' -or [IO.Path]::IsPathRooted($decoded) -or $decoded -match '^[A-Za-z]:'){return $null}
    $suffix='';$suffixIndex=$decoded.IndexOf('#');if($suffixIndex -ge 0){$suffix=$decoded.Substring($suffixIndex);$decoded=$decoded.Substring(0,$suffixIndex)}
    if(-not $decoded){return $null}
    $candidate=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($SourcePath)) ($decoded.Replace('/',[IO.Path]::DirectorySeparatorChar))))
    if(-not (Test-WithinRoot $candidate) -or $candidate -match '(?i)(^|[\\/])archive([\\/]|$)'){return $null}
    if([IO.Path]::GetExtension($candidate) -in @('.md','.json')){
        if(-not $script:IncludedSources.ContainsKey($candidate)){return $null}
        return ([IO.Path]::GetFileNameWithoutExtension($candidate)+'.html'+$suffix)
    }
    if(-not [IO.File]::Exists($candidate)){return $null}
    (Get-OutputRelativePath $candidate)+$suffix
}
function Inline([string]$Text,[string]$SourcePath){
    $encoded=Encode $Text
    $encoded=[regex]::Replace($encoded,'\[([^\]]+)\]\(([^)]+)\)',[Text.RegularExpressions.MatchEvaluator]{param($m)
        $label=$m.Groups[1].Value;$href=Resolve-DocumentationLink $m.Groups[2].Value $SourcePath
        if($null -eq $href){return '<span>'+$label+' (未產生或不安全的連結)</span>'}
        '<a href="'+(Encode $href)+'">'+$label+'</a>'
    })
    $encoded=[regex]::Replace($encoded,'`([^`]+)`','<code>$1</code>')
    [regex]::Replace($encoded,'\*\*([^*]+)\*\*','<strong>$1</strong>')
}
function Render([string]$Text,[string]$SourcePath){
    $out=New-Object Text.StringBuilder;$fence=$false;$table=$false;$list=$false
    foreach($line in ($Text -split '\r?\n')){
        if($line -match '^\s*```'){if($table){[void]$out.Append('</tbody></table></div>');$table=$false};if($list){[void]$out.Append('</ul>');$list=$false};if($fence){[void]$out.Append('</code></pre>')}else{[void]$out.Append('<pre><code>')};$fence=-not $fence;continue}
        if($fence){[void]$out.Append((Encode $line)+"`n");continue}
        if($line.Trim().StartsWith('|')){if($line -match '^\s*\|[\s:|\-]+\|\s*$'){continue};$cells=$line.Trim().Trim('|').Split('|');if(-not $table){[void]$out.Append('<div class="table-wrap"><table><tbody>');$table=$true};[void]$out.Append('<tr>');foreach($cell in $cells){[void]$out.Append('<td>'+(Inline $cell.Trim() $SourcePath)+'</td>')};[void]$out.Append('</tr>');continue}
        if($table){[void]$out.Append('</tbody></table></div>');$table=$false}
        if($line -match '^\s*(?:[-*]|\d+\.)\s+(.+)$'){if(-not $list){[void]$out.Append('<ul>');$list=$true};[void]$out.Append('<li>'+(Inline $matches[1] $SourcePath)+'</li>');continue}
        if($list){[void]$out.Append('</ul>');$list=$false}
        if($line -match '^(#{1,6})\s+(.+)$'){$level=$matches[1].Length;[void]$out.Append('<h'+$level+'>'+(Inline $matches[2] $SourcePath)+'</h'+$level+'>')}
        elseif(-not [string]::IsNullOrWhiteSpace($line)){[void]$out.Append('<p>'+(Inline $line $SourcePath)+'</p>')}
    }
    if($fence){[void]$out.Append('</code></pre>')};if($table){[void]$out.Append('</tbody></table></div>')};if($list){[void]$out.Append('</ul>')};$out.ToString()
}
function Get-ManualLink([string]$RelativePath,[string]$Label){
    $candidate=[IO.Path]::GetFullPath((Join-Path $script:ProjectRoot ($RelativePath.Replace('/',[IO.Path]::DirectorySeparatorChar))))
    if((Test-WithinRoot $candidate) -and [IO.File]::Exists($candidate) -and $candidate -notmatch '(?i)(^|[\\/])archive([\\/]|$)'){
        return '<a href="'+(Encode (Get-OutputRelativePath $candidate))+'">'+(Encode $Label)+'</a>'
    }
    '<span>'+(Encode $Label)+'</span>'
}
$docsRoot=Join-Path $script:ProjectRoot 'docs'
$sources=@(Get-Item -LiteralPath (Join-Path $script:ProjectRoot 'README.md'))+@(Get-ChildItem -LiteralPath $docsRoot -File | Where-Object {$_.Extension -in @('.md','.json') -and $_.Name -notmatch '(?i)^MIGRATION-.*-PLAN\.md$'})
foreach($source in $sources){$script:IncludedSources[[IO.Path]::GetFullPath($source.FullName)]=$true}
[void][IO.Directory]::CreateDirectory($script:OutputRoot)
$outputDirectory=Get-Item -LiteralPath $script:OutputRoot -Force
if(($outputDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Documentation output root cannot be a reparse point.'}
$manual=Get-ManualLink 'docs/ASSISTIVE-OPERATIONS.html' '完整操作手冊'
$categories=[ordered]@{
    '快速開始與日常操作'=@('README','OPERATIONS','GENERAL-HOST-WORKFLOW')
    '盤點清單與差異審閱'=@('ENTERPRISE-MIGRATION-COVERAGE','ENVIRONMENT-SOFTWARE-CONFIRMATION','SUPPORT-MATRIX')
    '復原、版本與資格'=@('RECOVERY-RUNBOOK','IMPLEMENTATION-0.1','RELEASE-NOTES-0.3','RELEASE-QUALIFICATION','RELEASE-SBOM')
    '參考資料'=@()
}
$categoryDescriptions=@{
    '快速開始與日常操作'='第一次使用或需要完成來源、管理、目標主機日常步驟時閱讀。'
    '盤點清單與差異審閱'='需要確認盤點範圍、軟體責任、支援項目及逐項差異時使用。'
    '復原、版本與資格'='作業中斷、需查版本變更，或確認工具／環境資格狀態時使用。'
    '參考資料'='其他使用者參考文件；每頁會保留來源路徑供追查。'
}
$documentDescriptions=@{
    'README'='認識工具用途、限制與從哪裡開始。'
    'OPERATIONS'='依操作階段查找入口、材料與責任。'
    'GENERAL-HOST-WORKFLOW'='一般主機、服務及排程工作負載的流程。'
    'ENTERPRISE-MIGRATION-COVERAGE'='逐項確認企業情境是否納入及如何處置。'
    'ENVIRONMENT-SOFTWARE-CONFIRMATION'='記錄軟體、版本、架構與手動補裝責任。'
    'SUPPORT-MATRIX'='查閱目前支援範圍與限制。'
    'RECOVERY-RUNBOOK'='作業失敗、中斷、對帳、續跑或回復時查閱。'
    'IMPLEMENTATION-0.1'='查看現行實作狀態、已知限制與外部驗收項目。'
    'RELEASE-NOTES-0.3'='了解版本變更及操作影響。'
    'RELEASE-QUALIFICATION'='查看工具與環境資格證據及尚未驗證條件。'
    'RELEASE-SBOM'='查閱發行套件的軟體材料清單。'
}
$categoryLinks=@{}
$orderedSources=@($sources | Sort-Object { if($_.Name -eq 'README.md'){ '0' } else { '1'+$_.Name } })
foreach($source in $orderedSources){
    $title=[IO.Path]::GetFileNameWithoutExtension($source.Name);$name=$title+'.html';$text=[IO.File]::ReadAllText($source.FullName);$sourceHash=(Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $relativeSource=$source.FullName.Substring($script:ProjectRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar).Replace('\','/')
    $manual=Get-ManualLink 'docs/ASSISTIVE-OPERATIONS.html' '完整操作手冊'
    $pageTemplate=@(
        '<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="documentation-generator" content="Build-HtmlDocumentation"><meta name="source-path" content="{0}"><meta name="source-sha256" content="{1}"><title>{2}</title><link rel="stylesheet" href="manual.css"></head><body><main><nav><a href="index.html">文件中心</a> · {3}</nav><p class="notice">離線文件快照；此頁不會執行搬移。實際結果及環境探測與正式資格分別確認。</p>{4}</main></body></html>'
    ) -join ''
    $content=if($source.Extension -ieq '.json'){'<h1>'+(Encode $title)+'</h1><pre><code>'+(Encode $text)+'</code></pre>'}else{Render $text $source.FullName}
    $page=$pageTemplate -f (Encode $relativeSource),$sourceHash,(Encode $title),$manual,$content
    [IO.File]::WriteAllText((Join-Path $script:OutputRoot $name),$page,(New-Object Text.UTF8Encoding($false)))
    $key=$source.BaseName
    $category='參考資料'
    foreach($candidateCategory in @($categories.Keys | Where-Object { $categories[$_] -contains $key })){$category=$candidateCategory;break}
    if(-not $categoryLinks.ContainsKey($category)){$categoryLinks[$category]=New-Object Text.StringBuilder}
    $description=$documentDescriptions[$key];if(-not $description){$description='供使用者查閱的參考文件。'}
    $linkTemplate='<li><a href="{0}">{1}</a><span>{2}</span><span class="doc-origin">來源：{3}</span></li>'
    [void]$categoryLinks[$category].Append(($linkTemplate -f (Encode $name),(Encode $title),(Encode $description),(Encode $relativeSource)))
}
$css=':root{color-scheme:light;--muted:#526778;--line:#d3dee6}body{margin:0;background:#f3f6fa;color:#172d45;font:16px/1.7 "Segoe UI","Microsoft JhengHei",sans-serif}main{max-width:1100px;margin:auto;padding:24px}a{color:#1254a0;overflow-wrap:anywhere}a:focus-visible{outline:3px solid #c47500;outline-offset:3px}h1,h2,h3{line-height:1.35}code{background:#e4ebf3;padding:2px 5px;overflow-wrap:anywhere}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#e4ebf3;padding:16px}.notice{border-left:4px solid #1254a0;padding:12px;background:white}.table-wrap{overflow:auto}table{border-collapse:collapse;width:100%;background:white}td{border:1px solid #abb9c9;padding:10px;vertical-align:top;min-width:130px}nav{padding:12px 0}.eyebrow{color:#1254a0;font-size:.88rem;font-weight:700;letter-spacing:.04em}.doc-category{border-top:1px solid var(--line);padding-top:1rem;margin-top:1.5rem}.doc-category li{margin:.6rem 0}.doc-origin{display:block;color:var(--muted);font-size:.88rem}@media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}}@media print{body{background:white}main{max-width:none;padding:0}.table-wrap{overflow:visible}tr{break-inside:avoid}}'
[IO.File]::WriteAllText((Join-Path $script:OutputRoot 'manual.css'),$css,(New-Object Text.UTF8Encoding($false)))
$indexTemplate=@(
    '<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>文件中心｜Windows Server Migration</title><link rel="stylesheet" href="manual.css"></head><body><main><p class="eyebrow">使用者文件 · 可離線閱讀</p><h1>操作與交接文件中心</h1><p class="notice">建議先讀{0}。以下是操作手冊與支援資料；文件為產生當下的離線快照，不會執行操作，也不代表目前工作區已達成本文所述狀態。</p><p>即時狀態以工作台顯示的來源、配對、revision、收據、階段結果及證據時間為準。機密原設定保存在受控材料。開發規劃不列入此文件中心；README、操作說明與參考資料仍依原始來源產生。</p>{1}</main></body></html>'
) -join ''
$sectionHtml=New-Object Text.StringBuilder
foreach($category in $categories.Keys){
    if($categoryLinks.ContainsKey($category) -and $categoryLinks[$category].Length -gt 0){
        [void]$sectionHtml.Append('<section class="doc-category"><h2>'+(Encode $category)+'</h2><p>'+(Encode $categoryDescriptions[$category])+'</p><ul>'+$categoryLinks[$category].ToString()+'</ul></section>')
    }
}
$index=$indexTemplate -f $manual,$sectionHtml.ToString()
[IO.File]::WriteAllText((Join-Path $script:OutputRoot 'index.html'),$index,(New-Object Text.UTF8Encoding($false)))
foreach($stale in @(Get-ChildItem -LiteralPath $script:OutputRoot -Filter '*.html' -File)){
    if($stale.Name -eq 'index.html'){continue}
    if($stale.Name -notmatch '(?i)^MIGRATION-.*-PLAN\.html$'){continue}
    if(($stale.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){continue}
    $existing=[IO.File]::ReadAllText($stale.FullName)
    $sourceMetadata=[regex]::Match($existing,'(?is)<meta\s+name="source-path"\s+content="(docs/(?:plans/)?MIGRATION-[^"/]+-PLAN\.md)"\s*/?>')
    $hashMetadata=[regex]::Match($existing,'(?is)<meta\s+name="source-sha256"\s+content="([a-f0-9]{64})"\s*/?>')
    $knownTemplate=($existing -match '(?is)<link\s+rel="stylesheet"\s+href="manual\.css"\s*/?>' -and $existing -match '(?is)<p\s+class="notice">離線文件快照；此頁不會執行搬移。')
    $knownCurrentTemplate=$existing -match '(?is)<meta\s+name="documentation-generator"\s+content="Build-HtmlDocumentation"\s*/?>'
    if($sourceMetadata.Success -and $hashMetadata.Success -and ($knownTemplate -or $knownCurrentTemplate)){
        Remove-Item -LiteralPath $stale.FullName -Force
    }
}
Write-Output ('Generated '+$sources.Count+' complete HTML documents and index; archive excluded.')
