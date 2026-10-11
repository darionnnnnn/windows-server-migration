#requires -Version 5.1
$ErrorActionPreference='Stop'
$passed=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:passed++}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('wsm-html-docs-'+[Guid]::NewGuid().ToString('N'))
$docs=Join-Path $fixture 'docs';$archive=Join-Path $docs 'archive';$output=Join-Path $docs 'html'
[void][IO.Directory]::CreateDirectory($archive)
[void][IO.Directory]::CreateDirectory($output)
$archiveLock=$null;$planLink=$null;$externalPlanTarget=$null
try {
    $longTail='DOCUMENT_END_MARKER_中文'
    $longText='Long body '+(('complete content 中文 data. ')*12000)+$longTail
    $readme=@"
# Fixture Documentation

This is a long page: $longText

[guide](docs/Guide.md#details) [plan 1](docs/MIGRATION-1-PLAN.md) [plan 3](docs/MIGRATION-3-PLAN.md) [plan 4](docs/MIGRATION-4-PLAN.md) [existing html](docs/legacy.html)
[support](docs/SUPPORT-MATRIX.json)
[script](javascript:alert(1)) [data](data:text/html,hello) [file](file:///secret) [https](https://example.com/docs)
[injected label](javascript:alert(1))
<script>alert('raw')</script><img src=x onerror=alert(1)>
"@
    $guide=@'
# Guide

[sibling](Sibling.md) [archived](archive/secret.md)
"<script>alert(2)</script>"
'@
    [IO.File]::WriteAllText((Join-Path $fixture 'README.md'),$readme,(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $docs 'Guide.md'),$guide,(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $docs 'Sibling.md'),'# Sibling',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $docs 'SUPPORT-MATRIX.json'),'{"Status":"NotTested","literal":"<script>unsafe</script>"}',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $docs 'OPERATIONS.md'),'# 操作指南',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $docs 'GENERAL-HOST-WORKFLOW.md'),'# 一般主機工作流程',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $docs 'IMPLEMENTATION-0.1.md'),'# 實作現況',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $docs 'RECOVERY.md'),'# 復原指南',(New-Object Text.UTF8Encoding($false)))
    foreach($iteration in 1,2,3,4){[IO.File]::WriteAllText((Join-Path $docs ('MIGRATION-'+$iteration+'-PLAN.md')),'EXCLUDED_PLAN_'+$iteration,(New-Object Text.UTF8Encoding($false)))}
    [IO.File]::WriteAllText((Join-Path $docs 'legacy.html'),'<p>existing artifact</p>',(New-Object Text.UTF8Encoding($false)))
    $staleHash=(Get-FileHash -LiteralPath (Join-Path $docs 'MIGRATION-3-PLAN.md') -Algorithm SHA256).Hash.ToLowerInvariant()
    $legacyStale='<!doctype html><html><head><meta name="source-path" content="docs/MIGRATION-3-PLAN.md"><meta name="source-sha256" content="'+$staleHash+'"><link rel="stylesheet" href="manual.css"></head><body><p class="notice">離線文件快照；此頁不會執行搬移。測試舊模板</p></body></html>'
    [IO.File]::WriteAllText((Join-Path $output 'MIGRATION-3-PLAN.html'),$legacyStale,(New-Object Text.UTF8Encoding($false)))
    $newStale='<meta name="documentation-generator" content="Build-HtmlDocumentation"><meta name="source-path" content="docs/plans/MIGRATION-2-PLAN.md"><meta name="source-sha256" content="'+$staleHash+'">'
    [IO.File]::WriteAllText((Join-Path $output 'MIGRATION-2-PLAN.html'),$newStale,(New-Object Text.UTF8Encoding($false)))
    $handwrittenPath=Join-Path $output 'handwritten.html';[IO.File]::WriteAllText($handwrittenPath,'<h1>手寫文件必須保留</h1>',(New-Object Text.UTF8Encoding($false)))
    $unknownPlanPath=Join-Path $output 'MIGRATION-99-PLAN.html';[IO.File]::WriteAllText($unknownPlanPath,'<h1>同名手寫 PLAN 必須保留</h1>',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $output 'unrecognized-plan.html'),'<meta name="source-path" content="docs/plans/MIGRATION-4-PLAN.md"><h1>無產生器標記</h1>',(New-Object Text.UTF8Encoding($false)))
    $externalPlanTarget=Join-Path $fixture 'external-plan-target.html';[IO.File]::WriteAllText($externalPlanTarget,'<meta name="source-path" content="docs/MIGRATION-3-PLAN.md"><meta name="source-sha256" content="'+$staleHash+'"><link rel="stylesheet" href="manual.css"><p class="notice">離線文件快照；此頁不會執行搬移。</p>',(New-Object Text.UTF8Encoding($false)))
    $planLink=Join-Path $output 'MIGRATION-98-PLAN.html';try{New-Item -ItemType SymbolicLink -Path $planLink -Target $externalPlanTarget -ErrorAction Stop | Out-Null}catch{$planLink=$null}
    $archiveSecret=Join-Path $archive 'secret.md';[IO.File]::WriteAllText($archiveSecret,'ARCHIVE_CONTENT_MUST_NEVER_BE_READ',(New-Object Text.UTF8Encoding($false)))
    $archiveLock=[IO.File]::Open($archiveSecret,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)

    & (Join-Path $PSScriptRoot '..\tools\Build-HtmlDocumentation.ps1') -ProjectRoot $fixture | Out-Null
    $index=[IO.File]::ReadAllText((Join-Path $output 'index.html'))
    $pagePath=Join-Path $output 'README.html';$page=[IO.File]::ReadAllText($pagePath)
    $guidePage=[IO.File]::ReadAllText((Join-Path $output 'Guide.html'))
    $sourceHash=(Get-FileHash -LiteralPath (Join-Path $fixture 'README.md') -Algorithm SHA256).Hash.ToLowerInvariant()
    Check ($page.Contains($longTail) -and $page.Length -gt 250000) 'Builder truncated long Markdown content instead of rendering the complete source.'
    Check ($page.Contains('name="source-sha256" content="'+$sourceHash+'"') -and $page.Contains('name="source-path" content="README.md"')) 'HTML page is missing traceable source path/hash metadata.'
    Check ($page.Contains('href="Guide.html#details"') -and $index.Contains('href="Guide.html"')) 'Existing relative Markdown links did not resolve to generated HTML artifacts.'
    Check ($page.Contains('href="SUPPORT-MATRIX.html"') -and $index.Contains('href="SUPPORT-MATRIX.html"')) 'JSON support document did not resolve to a portable HTML artifact.'
    $jsonPage=[IO.File]::ReadAllText((Join-Path $output 'SUPPORT-MATRIX.html'))
    Check ($jsonPage.Contains('NotTested') -and $jsonPage.Contains('&lt;script&gt;') -and -not $jsonPage.Contains('<script>')) 'JSON document was omitted or emitted as executable markup.'
    Check ($page.Contains('href="../legacy.html"')) 'Existing relative HTML artifact link was dropped or mapped incorrectly.'
    Check ($page.Contains('href="https://example.com/docs"')) 'A valid HTTPS link was dropped.'
    Check ($page.Contains('未產生或不安全的連結') -and -not $page.Contains('href="MIGRATION-1-PLAN.html"') -and -not $page.Contains('href="MIGRATION-3-PLAN.html"') -and -not $page.Contains('href="MIGRATION-4-PLAN.html"')) 'A migration plan without a generated artifact was emitted as a broken link.'
    Check (-not $page.Contains('href="javascript:') -and -not $page.Contains('href="data:') -and -not $page.Contains('href="file:')) 'A dangerous scheme was emitted as a clickable link.'
    Check (-not $page.Contains('<script>') -and -not $page.Contains('<img src=x') -and -not $guidePage.Contains('<script>')) 'HTML/script content from Markdown was not safely encoded.'
    Check (-not $index.Contains('ARCHIVE_CONTENT_MUST_NEVER_BE_READ') -and -not $page.Contains('ARCHIVE_CONTENT_MUST_NEVER_BE_READ') -and $guidePage.Contains('archived (未產生或不安全的連結)')) 'Archive content was read or archive reference was not rendered as inert text.'
    Check (-not $index.Contains('MIGRATION-1-PLAN.html') -and -not $index.Contains('MIGRATION-2-PLAN.html') -and -not $index.Contains('MIGRATION-3-PLAN.html') -and -not $index.Contains('MIGRATION-4-PLAN.html') -and -not $index.Contains('EXCLUDED_PLAN_')) 'A migration plan iteration was included in the generated documentation set.'
    Check (-not [IO.File]::Exists((Join-Path $output 'MIGRATION-2-PLAN.html')) -and -not [IO.File]::Exists((Join-Path $output 'MIGRATION-3-PLAN.html')) -and [IO.File]::Exists($handwrittenPath) -and [IO.File]::Exists($unknownPlanPath) -and [IO.File]::Exists((Join-Path $output 'unrecognized-plan.html'))) 'Stale recognized PLAN output was not removed or a same-pattern handwritten HTML artifact was deleted.'
    Check ([IO.File]::ReadAllText($externalPlanTarget).Contains('MIGRATION-3-PLAN.md') -and ($null -eq $planLink -or [IO.File]::Exists($planLink))) 'A reparse-point PLAN candidate was followed or deleted.'
    Check ($index.Contains('快速開始與日常操作') -and $index.Contains('盤點清單與差異審閱') -and $index.Contains('復原、版本與資格') -and $index.Contains('第一次使用') -and $index.Contains('逐項差異') -and $index.Contains('docs/')) 'Generated index is not categorized as user-facing documentation with source paths and descriptions.'
    $generatedSources=@(Get-ChildItem -LiteralPath $output -Filter '*.html' -File | Where-Object {$_.Name -notin @('index.html','handwritten.html','MIGRATION-99-PLAN.html','MIGRATION-98-PLAN.html','unrecognized-plan.html')})
    foreach($generated in $generatedSources){$html=[IO.File]::ReadAllText($generated.FullName);$relative=[regex]::Match($html,'(?is)<meta name="source-path" content="([^"]+)"').Groups[1].Value;$source=Join-Path $fixture $relative.Replace('/',[IO.Path]::DirectorySeparatorChar);$actual=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant();Check ($html.Contains('name="source-sha256" content="'+$actual+'"')) ('Generated HTML does not bind the original source bytes: '+$generated.Name)}
    Check ($page.Contains('<span>完整操作手冊</span>') -and -not $page.Contains('href="../ASSISTIVE-OPERATIONS.html"')) 'Missing manual artifact was left as a broken navigation link.'
    Write-Host ('PASS: '+$passed+' HTML documentation checks.')
} finally {
    if($archiveLock){$archiveLock.Dispose()}
    if($planLink -and [IO.File]::Exists($planLink)){Remove-Item -LiteralPath $planLink -Force}
    if([IO.Directory]::Exists($fixture)){
        $fullFixture=[IO.Path]::GetFullPath($fixture);$tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
        if(-not $fullFixture.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing to clean a fixture outside the temporary directory.'}
        Remove-Item -LiteralPath $fullFixture -Recurse -Force
    }
}
