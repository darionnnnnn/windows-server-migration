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
    & $module {
        param($Root)
        $tool=Get-WsmToolFingerprint;$pair=[Guid]::NewGuid().ToString('D');$batch=[Guid]::NewGuid().ToString('D');$sourceId=[Guid]::NewGuid().ToString('D');$targetId=[Guid]::NewGuid().ToString('D');$approval=[Guid]::NewGuid().ToString('D');$packageId=[Guid]::NewGuid().ToString('D');$planHash='a'*64;$manifestHash='b'*64
        $manifest=[pscustomobject]@{PairId=$pair;BatchId=$batch;PlanHash=$planHash;PackageId=$packageId;Generation=7;BaseManifestHash='';Source=[pscustomobject]@{HostId=$sourceId;Fingerprint='c'*64};Target=[pscustomobject]@{HostId=$targetId;Fingerprint='d'*64}}
        $plan=[pscustomobject]@{ApprovalId=$approval;ToolFingerprint=$tool}
        $receipt=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='DeliveryReceipt';ReceiptId=[Guid]::NewGuid().ToString('D');DeliveryId=[Guid]::NewGuid().ToString('D');Status='ImportedVerified';Mode='Zip';OperationKind='Full';MigrationMode='IsolatedPilot';BaseVerificationStatus='None';PairId=$pair;BatchId=$batch;SourceHostId=$sourceId;SourceFingerprint=$manifest.Source.Fingerprint;TargetHostId=$targetId;TargetFingerprint=$manifest.Target.Fingerprint;ToolFingerprint=$tool;ApprovalId=$approval;PlanHash=$planHash;Generation=7;PackageId=$packageId;ManifestHash=$manifestHash;BaseManifestHash='';TransportHash='e'*64;VolumeBytes=1048576;Volumes=@([pscustomobject]@{Name=('package-'+$packageId+'-0001.zip');Number=1;Bytes=100;SHA256='f'*64});Members=@([pscustomobject]@{Name='manifest.json';Bytes=10;SHA256='1'*64});TotalVolumeBytes=100;CreatedUtc=[DateTime]::UtcNow.ToString('o');ReportOnly=$true;ReadinessProof=$false;ProductionVerified=$false}
        $receiptPath=Join-Path $Root 'delivery-receipt.json';Write-WsmJson $receiptPath $receipt;$receiptHash=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant();$refs=@([pscustomobject]@{Path=$receiptPath;SHA256=$receiptHash})
        $safe=@(Assert-WsmLabDeliveryReceiptReferences -References $refs -Manifest $manifest -Plan $plan -ManifestHash $manifestHash -ToolFingerprint $tool)
        if($safe.Count -ne 1 -or $safe[0].Status -cne 'ImportedVerified' -or -not $safe[0].ReportOnly -or $safe[0].ReadinessProof -or $safe[0].ProductionVerified){throw 'Lab delivery receipt reference was not retained as an exact report-only projection.'}
        $badHashRejected=$false;try{[void](Assert-WsmLabDeliveryReceiptReferences -References @([pscustomobject]@{Path=$receiptPath;SHA256=('0'*64)}) -Manifest $manifest -Plan $plan -ManifestHash $manifestHash -ToolFingerprint $tool)}catch{$badHashRejected=$true}
        $wrongManifest=$manifest|ConvertTo-Json -Depth 8|ConvertFrom-Json;$wrongManifest.Target.Fingerprint='9'*64;$wrongBindingRejected=$false;try{[void](Assert-WsmLabDeliveryReceiptReferences -References $refs -Manifest $wrongManifest -Plan $plan -ManifestHash $manifestHash -ToolFingerprint $tool)}catch{$wrongBindingRejected=$true}
        $tooManyRejected=$false;try{[void](Assert-WsmLabDeliveryReceiptReferences -References (@($refs*21)) -Manifest $manifest -Plan $plan -ManifestHash $manifestHash -ToolFingerprint $tool)}catch{$tooManyRejected=$true}
        if(-not $badHashRejected -or -not $wrongBindingRejected -or -not $tooManyRejected){throw 'Lab delivery receipt reference accepted a bad hash, endpoint binding, or more than 20 references.'}
    } $root
    Write-Host 'PASS: actual CLI lab environment output, invalid-hash exit code, wizard route, and exact report-only delivery-receipt consumer with hash/binding/count rejection.'
} finally {
    $resolved=[IO.Path]::GetFullPath($root).TrimEnd('\');$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if(-not $resolved.StartsWith($temp+'\',[StringComparison]::OrdinalIgnoreCase) -or $resolved -notmatch '\\wsm-lab-consumer-[0-9a-f]{32}$'){throw 'Lab consumer fixture cleanup guard failed.'}
    if([IO.Directory]::Exists($resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
    $global:LASTEXITCODE=0
}
