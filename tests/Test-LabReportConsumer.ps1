#requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$module=Import-Module (Join-Path $repo 'src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-lab-consumer-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    if(-not (Get-Command Export-WsmLabValidationReport -ErrorAction SilentlyContinue)){throw 'Lab report API is not publicly exported.'}
    $engine=Join-Path $PSHOME 'powershell.exe';if(-not [IO.File]::Exists($engine)){$engine=Join-Path $PSHOME 'pwsh.exe'}
    $entry=Join-Path $repo 'Start-ServerMigration.ps1';$output=Join-Path $root 'cli-environment';$log=Join-Path $root 'cli.log'
    $ErrorActionPreference='Continue'
    & $engine -NoProfile -NonInteractive -File $entry -Action LabReport -Role Target -Path $output *> $log
    $code=$LASTEXITCODE;$ErrorActionPreference='Stop'
    if($code -notin @(0,2)){throw ('LabReport CLI failed to produce environment-only output: '+(Get-Content -LiteralPath $log -Raw))}
    $jsonFiles=@(Get-ChildItem -LiteralPath $output -Recurse -File -Filter '*.json');$textFiles=@(Get-ChildItem -LiteralPath $output -Recurse -File -Filter '*.txt')
    if($jsonFiles.Count -ne 1 -or $textFiles.Count -ne 1){throw 'LabReport CLI did not return exactly one JSON and copy/paste text report.'}
    $report=Get-Content -LiteralPath $jsonFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if($report.Kind -cne 'LabValidationReport' -or $report.Role -cne 'Target' -or $report.ProductionVerified -ne $false -or @($report.Checks | Where-Object {$_.Code -ceq 'ApprovedPackage' -and $_.Status -ceq 'NotTested'}).Count -ne 1){throw 'Environment report falsely claimed package verification.'}
    $text=Get-Content -LiteralPath $textFiles[0].FullName -Raw;$hash=(Get-FileHash -LiteralPath $jsonFiles[0].FullName).Hash
    if($text -notmatch [regex]::Escape($hash)){throw 'Copy/paste report omitted the exact JSON checksum.'}
    $invalidOutput=Join-Path $root 'invalid';$ErrorActionPreference='Continue'
    & $engine -NoProfile -NonInteractive -File $entry -Action LabReport -Role Source -Path $invalidOutput -ManifestPath (Join-Path $root 'absent-manifest.json') -ExpectedHash 'bad' *> (Join-Path $root 'invalid.log')
    $code=$LASTEXITCODE;$ErrorActionPreference='Stop'
    if($code -ne 4 -or [IO.Directory]::Exists($invalidOutput)){throw 'Invalid lab report hash was not rejected before output creation.'}
    & $module {
        param($Output)
        $script:labMenuAnswers=New-Object 'System.Collections.Generic.Queue[object]'
        foreach($answer in @('6','Target','1',$Output,'0')){$script:labMenuAnswers.Enqueue($answer)}
        $script:labMenuCalls=New-Object 'System.Collections.Generic.List[object]'
        function Read-Host {param($Prompt)if(-not $script:labMenuAnswers.Count){throw 'Unexpected lab wizard prompt.'};$script:labMenuAnswers.Dequeue()}
        function Export-WsmLabValidationReport {param($OutputDirectory,$Role,$ManifestPath,$ExpectedHash,$StateDirectory,$Phase)$script:labMenuCalls.Add([pscustomobject]@{OutputDirectory=$OutputDirectory;Role=$Role;ManifestPath=$ManifestPath;StateDirectory=$StateDirectory});[pscustomobject]@{TextPath='fixture.txt';Blocked=$true}}
        Show-WsmMigrationWizard 'unused-fixture'
        if($script:labMenuAnswers.Count -ne 0 -or $script:labMenuCalls.Count -ne 1 -or $script:labMenuCalls[0].Role -cne 'Target' -or $script:labMenuCalls[0].ManifestPath -or $script:labMenuCalls[0].StateDirectory){throw 'Lab wizard environment consumer passed the wrong bindings.'}
    } (Join-Path $root 'menu-environment')
    Write-Host 'PASS: actual CLI lab environment output and invalid-hash exit code; exported API and role-6 wizard route without requiring target state for environment readiness.'
} finally {
    $resolved=[IO.Path]::GetFullPath($root).TrimEnd('\');$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if(-not $resolved.StartsWith($temp+'\',[StringComparison]::OrdinalIgnoreCase) -or $resolved -notmatch '\\wsm-lab-consumer-[0-9a-f]{32}$'){throw 'Lab consumer fixture cleanup guard failed.'}
    if([IO.Directory]::Exists($resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
    $global:LASTEXITCODE=0
}