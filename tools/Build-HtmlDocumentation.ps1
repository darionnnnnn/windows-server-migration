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
    if([IO.Path]::GetExtension($candidate) -ieq '.md'){
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
$sources=@(Get-Item -LiteralPath (Join-Path $script:ProjectRoot 'README.md'))+@(Get-ChildItem -LiteralPath $docsRoot -File -Filter '*.md' | Where-Object Name -NE 'MIGRATION-3-PLAN.md')
foreach($source in $sources){$script:IncludedSources[[IO.Path]::GetFullPath($source.FullName)]=$true}
[void][IO.Directory]::CreateDirectory($script:OutputRoot)
$links=New-Object Text.StringBuilder
foreach($source in $sources){
    $title=[IO.Path]::GetFileNameWithoutExtension($source.Name);$name=$title+'.html';$text=[IO.File]::ReadAllText($source.FullName);$sourceHash=(Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $relativeSource=$source.FullName.Substring($script:ProjectRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar).Replace('\','/')
    $manual=Get-ManualLink 'docs/ASSISTIVE-OPERATIONS.html' '第三輪操作手冊'
    $pageTemplate=@(
        '<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="source-path" content="{0}"><meta name="source-sha256" content="{1}"><title>{2}</title><link rel="stylesheet" href="manual.css"></head><body><main><nav><a href="index.html">文件中心</a> · {3}</nav><p class="notice">離線文件快照；此頁不會執行搬移。實際結果及環境探測與正式資格分別確認。</p>{4}</main></body></html>'
    ) -join ''
    $page=$pageTemplate -f (Encode $relativeSource),$sourceHash,(Encode $title),$manual,(Render $text $source.FullName)
    [IO.File]::WriteAllText((Join-Path $script:OutputRoot $name),$page,(New-Object Text.UTF8Encoding($false)))
    $linkTemplate='<li><a href="{0}">{1}</a></li>'
    [void]$links.Append(($linkTemplate -f (Encode $name),(Encode $title)))
}
$css=':root{color-scheme:light}body{margin:0;background:#f3f6fa;color:#172d45;font:16px/1.7 "Segoe UI","Microsoft JhengHei",sans-serif}main{max-width:1100px;margin:auto;padding:24px}a{color:#1254a0;overflow-wrap:anywhere}a:focus-visible{outline:3px solid #c47500;outline-offset:3px}h1,h2,h3{line-height:1.35}code{background:#e4ebf3;padding:2px 5px;overflow-wrap:anywhere}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#e4ebf3;padding:16px}.notice{border-left:4px solid #1254a0;padding:12px;background:white}.table-wrap{overflow:auto}table{border-collapse:collapse;width:100%;background:white}td{border:1px solid #abb9c9;padding:10px;vertical-align:top;min-width:130px}nav{padding:12px 0}@media print{body{background:white}main{max-width:none;padding:0}.table-wrap{overflow:visible}tr{break-inside:avoid}}'
[IO.File]::WriteAllText((Join-Path $script:OutputRoot 'manual.css'),$css,(New-Object Text.UTF8Encoding($false)))
$manual=Get-ManualLink 'docs/ASSISTIVE-OPERATIONS.html' '第三輪操作手冊'
$indexTemplate=@(
    '<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>文件中心</title><link rel="stylesheet" href="manual.css"></head><body><main><h1>操作與交接文件中心</h1><p>先閱讀{0}。各文件是可攜離線快照，沒有執行按鈕；機密原設定另保存在受控材料。</p><ul>{1}</ul></main></body></html>'
) -join ''
$index=$indexTemplate -f $manual,$links.ToString()
[IO.File]::WriteAllText((Join-Path $script:OutputRoot 'index.html'),$index,(New-Object Text.UTF8Encoding($false)))
Write-Output ('Generated '+$sources.Count+' complete HTML documents and index; archive excluded.')
