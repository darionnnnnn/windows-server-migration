#requires -Version 5.1
# N6 (16.3-1)：離線使用說明產生器的內容、跳脫與不含絕對路徑／秘密。
# 交付鏈（Directory／ZIP、獨立副本、收據、竄改）的檢查在 Test-WizardBackup.ps1；這裡只驗產生器本身。
# -FixtureDir：把含中文、空白與注入字串的說明檔留給真實瀏覽器測試（Test-OfflineGuideBrowser.js）使用。
param([string]$FixtureDir='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
$work=$FixtureDir
$ownWork=$false
if(-not $work){$work=Join-Path ([IO.Path]::GetTempPath()) ('wsm-guide-'+[Guid]::NewGuid().ToString('N'));$ownWork=$true}
[void][IO.Directory]::CreateDirectory($work)
try{
    & $module {
        param($Work)
        $script:checks=0
        function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
        $manifestHash=('ab12'*16);$planHash=('cd34'*16);$deliveryHash=('ef56'*16);$resultsHash=('0a1b'*16);$reportHash=('2c3d'*16);$fingerprint=('9f8e'*16)
        $baseFacts=[ordered]@{ToolVersion='0.4.0';ToolFingerprint=$fingerprint;PairId='11111111-1111-4111-8111-111111111111';AttemptId='22222222-2222-4222-8222-222222222222';Mode='Directory';GeneratedUtc='2026-10-23T00:00:00Z';ManifestHash=$manifestHash;PlanHash=$planHash;DeliveryName='directory-delivery.json';DeliverySHA256=$deliveryHash;ItemResultsSHA256=$resultsHash;OfflineReportSHA256=$reportHash}

        # --- 1. normal facts: every required block, no network, no script, no absolute path.
        $dir1=Join-Path $Work 'normal';[void][IO.Directory]::CreateDirectory($dir1)
        $r1=Export-WsmBackupOfflineGuide (Join-Path $dir1 'offline-guide.html') (Join-Path $dir1 'offline-guide.txt') ([pscustomobject]$baseFacts)
        $html1=[IO.File]::ReadAllText($r1.Path);$txt1=[IO.File]::ReadAllText($r1.TextPath)
        Check ($r1.SHA256 -ceq (Get-FileHash -LiteralPath $r1.Path -Algorithm SHA256).Hash.ToLowerInvariant() -and $r1.TextSHA256 -ceq (Get-FileHash -LiteralPath $r1.TextPath -Algorithm SHA256).Hash.ToLowerInvariant()) 'The returned guide hashes differ from the files.'
        foreach($doc in @($html1,$txt1)){
            foreach($needle in @($manifestHash,$planHash,$deliveryHash,$resultsHash,$reportHash,$fingerprint,'0.4.0','directory-delivery.json','ToolVersion','取得','驗證','信任材料','匯入','不代表媒體目前仍完整','重新驗證','docs\html\OPERATIONS.html')){Check $doc.Contains($needle) ('The guide is missing: '+$needle)}
            Check ($doc -notmatch '(?i)[a-z]:\\' -and $doc -notmatch '(?i)https?://' -and $doc -notmatch '(?i)ftp://') 'The guide must not carry an absolute path or a download/network address.'
        }
        Check ($html1 -match '(?s)^<!doctype html>.*<html lang="zh-Hant">' -and $html1 -match '<h1>' -and ([regex]::Matches($html1,'<h2 id=')).Count -ge 6 -and ([regex]::Matches($html1,'<section aria-labelledby=')).Count -eq ([regex]::Matches($html1,'<h2 id=')).Count) 'The guide HTML must use semantic headings and labelled sections.'
        Check ($html1 -notmatch '(?i)<script|<link |<img |<iframe|onerror=|javascript:' -and $html1 -match "Content-Security-Policy" -and $html1 -match 'system-ui' -and $html1 -match 'Noto Sans TC' -and $html1 -match 'Microsoft JhengHei' -and $html1 -match 'prefers-reduced-motion') 'The guide HTML must be static (no script/link/img), carry the CSP, the required fonts and the reduced-motion rule.'
        Check ($html1 -match 'href="backup-report.html"') 'With a report hash the guide links to the report beside it.'
        Check ($txt1 -match "`r`n" -and $txt1 -notmatch '[\x00-\x08\x0b\x0c\x0e-\x1f]') 'The text fallback must use CRLF and carry no control characters.'
        $bytes1=[IO.File]::ReadAllBytes($r1.Path);Check ($bytes1.Length -gt 0 -and -not ($bytes1.Length -ge 3 -and $bytes1[0] -eq 0xEF)) 'The guide HTML is UTF-8 without BOM (charset is declared in meta).'
        # Same facts, same bytes: a resumed delivery regenerates the identical files.
        $dir1b=Join-Path $Work 'normal-again';[void][IO.Directory]::CreateDirectory($dir1b)
        $r1b=Export-WsmBackupOfflineGuide (Join-Path $dir1b 'offline-guide.html') (Join-Path $dir1b 'offline-guide.txt') ([pscustomobject]$baseFacts)
        Check ($r1b.SHA256 -ceq $r1.SHA256 -and $r1b.TextSHA256 -ceq $r1.TextSHA256) 'The same facts must regenerate byte-identical guide files.'

        # --- 2. ZIP mode and a missing report: the descriptor label follows the mode and there is no dangling report link.
        $zipFacts=[ordered]@{};foreach($k in $baseFacts.Keys){$zipFacts[$k]=$baseFacts[$k]};$zipFacts.Mode='Zip';$zipFacts.DeliveryName='transport.json';$zipFacts.ItemResultsSHA256='';$zipFacts.OfflineReportSHA256=''
        $dir2=Join-Path $Work 'zip';[void][IO.Directory]::CreateDirectory($dir2)
        $r2=Export-WsmBackupOfflineGuide (Join-Path $dir2 'offline-guide.html') (Join-Path $dir2 'offline-guide.txt') ([pscustomobject]$zipFacts)
        $html2=[IO.File]::ReadAllText($r2.Path)
        Check ($html2.Contains('transport.json') -and $html2.Contains('ZIP') -and $html2 -notmatch 'href="backup-report.html"' -and $html2.Contains('未記錄')) 'ZIP mode must name transport.json, mark missing hashes as not recorded and omit the report link.'

        # --- 3. hostile facts: Chinese, spaces, injection strings, absolute paths, control characters, bad hashes.
        $hostile=[ordered]@{ToolVersion="<script>alert('xss')</script>&""'";ToolFingerprint='not-a-hash';PairId='中文 空白 配對 & <b>bold</b>';AttemptId='"><img src=x onerror=alert(1)>';Mode='Directory';GeneratedUtc="2026-10-23`r`nINJECTED-LINE";ManifestHash='<script>alert(2)</script>';PlanHash=('CD34'*16);DeliveryName='C:\Users\某人\我的 資料\"><svg onload=alert(3)>.json';DeliverySHA256=$deliveryHash.ToUpperInvariant();ItemResultsSHA256='';OfflineReportSHA256=''}
        $dir3=Join-Path $Work 'hostile';[void][IO.Directory]::CreateDirectory($dir3)
        $r3=Export-WsmBackupOfflineGuide (Join-Path $dir3 'offline-guide.html') (Join-Path $dir3 'offline-guide.txt') ([pscustomobject]$hostile)
        $html3=[IO.File]::ReadAllText($r3.Path);$txt3=[IO.File]::ReadAllText($r3.TextPath)
        Check ($html3 -notmatch '(?i)<script|<img |<svg|<b>') 'Injected markup reached the guide HTML unescaped.'
        Check ($html3.Contains('&lt;img src=x onerror=alert(1)&gt;') -and $html3.Contains('&lt;svg onload=alert(3)&gt;')) 'Injected markup must appear as encoded text.'
        Check ($html3.Contains('&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;&amp;&quot;&#39;') -or $html3.Contains('&lt;script&gt;alert(')) 'The injected tool version was not HTML-encoded.'
        Check ($html3.Contains('中文 空白 配對 &amp; &lt;b&gt;bold&lt;/b&gt;')) 'Chinese text with spaces and markup characters must survive as encoded text.'
        Check ($html3 -notmatch 'INJECTED-LINE\r?\n' -and $txt3 -notmatch "(?m)^INJECTED-LINE") 'A control-character injection must not start a new line in either file.'
        Check ($html3 -notmatch '(?i)[a-z]:\\' -and $txt3 -notmatch '(?i)[a-z]:\\' -and $html3 -notmatch '某人' -and $txt3 -notmatch '某人') 'Only the descriptor file name may appear, never its absolute path.'
        Check ($html3.Contains($deliveryHash) -and -not $html3.Contains($deliveryHash.ToUpperInvariant())) 'Hashes must be normalised to lower case.'
        Check ($html3.Contains('<dd>未記錄</dd>') -and $txt3.Contains('未記錄')) 'Malformed hashes must be shown as not recorded, never echoed.'
        # The text fallback is plain text: no HTML entities are introduced.
        Check ($txt3 -notmatch '&lt;|&amp;|&quot;|&#39;') 'The text fallback must not contain HTML entities.'

        # --- 4. facts that are missing entirely: every value is "not recorded", the guide is still produced.
        $dir4=Join-Path $Work 'empty';[void][IO.Directory]::CreateDirectory($dir4)
        $r4=Export-WsmBackupOfflineGuide (Join-Path $dir4 'offline-guide.html') (Join-Path $dir4 'offline-guide.txt') ([pscustomobject]@{})
        Check ([IO.File]::ReadAllText($r4.Path).Contains('未記錄') -and [IO.File]::ReadAllText($r4.TextPath).Contains('未記錄')) 'An empty fact set must still produce a guide with not-recorded values.'

        # --- 5. verification helper: indexed guide files must exist and match; no record means nothing to check.
        $attempt=[pscustomobject]@{OfflineGuide=[pscustomobject]@{Status='Generated';Path=$r1.Path;SHA256=$r1.SHA256;TextPath=$r1.TextPath;TextSHA256=$r1.TextSHA256}}
        Check ($null -eq (Test-WsmBackupOfflineGuideFiles $attempt)) 'An intact guide must pass the delivery check.'
        Check ($null -eq (Test-WsmBackupOfflineGuideFiles ([pscustomobject]@{}))) 'An attempt without a guide record is not checked (older attempts).'
        Check ($null -eq (Test-WsmBackupOfflineGuideFiles ([pscustomobject]@{OfflineGuide=[pscustomobject]@{Status='Failed';Error='x'}}))) 'A failed guide generation is not an integrity failure.'
        $original=[IO.File]::ReadAllBytes($r1.TextPath)
        try{
            $changed=[byte[]]$original.Clone();$changed[0]=[byte]($changed[0] -bxor 1);[IO.File]::WriteAllBytes($r1.TextPath,$changed)
            Check ([bool](Test-WsmBackupOfflineGuideFiles $attempt)) 'A modified guide text must fail the delivery check.'
            [IO.File]::Delete($r1.TextPath)
            Check ([bool](Test-WsmBackupOfflineGuideFiles $attempt)) 'A missing guide text must fail the delivery check.'
        }finally{[IO.File]::WriteAllBytes($r1.TextPath,$original)}
        Check ($null -eq (Test-WsmBackupOfflineGuideFiles $attempt)) 'Restoring the bytes must pass the delivery check again.'
        Write-Output ('PASS: offline guide generator content, escaping, no absolute path, hash normalisation and delivery check ('+$script:checks+' checks).')
    } $work
}finally{
    if($ownWork){
        $full=[IO.Path]::GetFullPath($work);$tmp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if($full.StartsWith($tmp,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $full -Leaf) -like 'wsm-guide-*' -and [IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
    }
}
