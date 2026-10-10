#requires -Version 5.1
$ErrorActionPreference='Stop'
$passed=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:passed++}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('wsm-html-docs-'+[Guid]::NewGuid().ToString('N'))
$docs=Join-Path $fixture 'docs';$archive=Join-Path $docs 'archive';$output=Join-Path $docs 'html'
[void][IO.Directory]::CreateDirectory($archive)
$archiveLock=$null
try {
    $longTail='DOCUMENT_END_MARKER_中文'
    $longText='Long body '+(('complete content 中文 data. ')*12000)+$longTail
    $readme=@"
# Fixture Documentation

This is a long page: $longText

[guide](docs/Guide.md#details) [missing](docs/MISSING-3-PLAN.md) [existing html](docs/legacy.html)
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
    [IO.File]::WriteAllText((Join-Path $docs 'MIGRATION-3-PLAN.md'),'EXCLUDED_PLAN_CONTENT',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $docs 'legacy.html'),'<p>existing artifact</p>',(New-Object Text.UTF8Encoding($false)))
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
    Check ($page.Contains('未產生或不安全的連結') -and -not $page.Contains('href="MISSING-3-PLAN.html"')) 'A Markdown target without a generated artifact was emitted as a broken link.'
    Check (-not $page.Contains('href="javascript:') -and -not $page.Contains('href="data:') -and -not $page.Contains('href="file:')) 'A dangerous scheme was emitted as a clickable link.'
    Check (-not $page.Contains('<script>') -and -not $page.Contains('<img src=x') -and -not $guidePage.Contains('<script>')) 'HTML/script content from Markdown was not safely encoded.'
    Check (-not $index.Contains('ARCHIVE_CONTENT_MUST_NEVER_BE_READ') -and -not $page.Contains('ARCHIVE_CONTENT_MUST_NEVER_BE_READ') -and $guidePage.Contains('archived (未產生或不安全的連結)')) 'Archive content was read or archive reference was not rendered as inert text.'
    Check (-not $index.Contains('MIGRATION-3-PLAN.html') -and -not $index.Contains('EXCLUDED_PLAN_CONTENT')) 'Excluded migration plan was included in the generated documentation set.'
    Check ($page.Contains('<span>第三輪操作手冊</span>') -and -not $page.Contains('href="../ASSISTIVE-OPERATIONS.html"')) 'Missing manual artifact was left as a broken navigation link.'
    Write-Host ('PASS: '+$passed+' HTML documentation checks.')
} finally {
    if($archiveLock){$archiveLock.Dispose()}
    if([IO.Directory]::Exists($fixture)){
        $fullFixture=[IO.Path]::GetFullPath($fixture);$tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
        if(-not $fullFixture.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing to clean a fixture outside the temporary directory.'}
        Remove-Item -LiteralPath $fullFixture -Recurse -Force
    }
}
