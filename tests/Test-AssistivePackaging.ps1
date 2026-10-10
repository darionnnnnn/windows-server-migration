#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-source-retention-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($root)
        function Check($ok,$message){if(-not $ok){throw $message};$script:checks++}
        $script:checks=0
        $workspace=Join-Path $root 'source-state';[void][IO.Directory]::CreateDirectory($workspace);Protect-WsmDirectory $workspace
        $planPath=Join-Path $root 'plan.json';[IO.File]::WriteAllText($planPath,'fixture authenticated by isolated boundary')
        $planHash=(Get-FileHash -LiteralPath $planPath).Hash.ToLowerInvariant()
        $script:plan=[pscustomobject]@{SchemaVersion=3;PairId=[Guid]::NewGuid().ToString();Source=[pscustomobject]@{Fingerprint=('a'*64)}}
        # This tests source producer -> real graph/locks and filesystem seams.
        # Native Server authentication/package collector remain environment probes.
        function Read-WsmMigrationPlan {param($path,$hash) Assert-WsmTrustedFile $path $hash;$script:plan}
        function Assert-WsmMigrationHost {param($machine,$fingerprint)}
        function Assert-WsmSourceWorkspaceSeparation {param($plan,$path)}
        $script:failCapture=$false
        function Export-WsmMigrationPackageCore {
            param($PlanPath,$ExpectedHash,$SourceStateDirectory,$OutputDirectory)
            $registry=Get-WsmAssistiveResourceRegistry $SourceStateDirectory
            if(@($registry.LiveJobs).Count -ne 1){throw 'Source producer has no live retention lock.'}
            if($script:failCapture){throw 'isolated capture failure'}
            [void][IO.Directory]::CreateDirectory((Join-Path $OutputDirectory 'payload'))
            [IO.File]::WriteAllText((Join-Path $OutputDirectory 'manifest.json'),'fixture manifest')
            [IO.File]::Copy($PlanPath,(Join-Path $OutputDirectory 'plan.json'))
            $chunk=Join-Path $OutputDirectory 'payload\chunk.tmp';[IO.File]::WriteAllText($chunk,'preserved bytes')
            $chunkHash=(Get-FileHash -LiteralPath $chunk).Hash.ToLowerInvariant();[IO.File]::Move($chunk,(Join-Path $OutputDirectory ('payload\'+$chunkHash+'.blob')))
            $index=Join-Path $OutputDirectory 'artifacts.jsonl';$row=[pscustomobject]@{ItemId=('b'*64);Data=[pscustomobject]@{Chunks=@([pscustomobject]@{Hash=$chunkHash;Bytes=15})}}
            [IO.File]::WriteAllText($index,((ConvertTo-Json $row -Compress -Depth 5)+"`n"),(New-Object Text.UTF8Encoding($false)))
            $script:package=[pscustomobject]@{Root=$OutputDirectory;Manifest=[pscustomobject]@{ArtifactsHash=(Get-FileHash -LiteralPath $index).Hash.ToLowerInvariant()}}
            [pscustomobject]@{ManifestPath=(Join-Path $OutputDirectory 'manifest.json');SHA256=(Get-FileHash -LiteralPath (Join-Path $OutputDirectory 'manifest.json')).Hash.ToLowerInvariant()}
        }
        function Test-WsmMigrationPackage {param($path,$hash) Assert-WsmTrustedFile $path $hash;$script:package}
        $output=Join-Path $root 'package'
        $result=Export-WsmMigrationPackage -PlanPath $planPath -ExpectedHash $planHash -SourceStateDirectory $workspace -OutputDirectory $output
        $registry=Get-WsmAssistiveResourceRegistry $workspace
        Check ([IO.File]::Exists($result.ManifestPath)) 'Public producer failed to retain its sealed artifact.'
        Check ($registry.Materials.Count -eq 5 -and @($registry.Materials|Where-Object Kind -EQ PayloadChunk).Count -eq 1) 'Source graph omitted plan/control/payload materials.'
        Check (@($registry.LiveJobs).Count -eq 0) 'Completed source operation retained a live job lock.'
        $cleanup=Get-WsmAssistiveCleanupPreview -Workspace $workspace -RetentionBeforeUtc ([DateTime]::UtcNow.AddYears(1).ToString('o'))
        Check (@($cleanup.Rows|Where-Object Eligible).Count -eq 0) 'Unclosed source materials became eligible for deletion.'
        $script:failCapture=$true;$rejected=$false
        try{Export-WsmMigrationPackage -PlanPath $planPath -ExpectedHash $planHash -SourceStateDirectory $workspace -OutputDirectory (Join-Path $root 'failed')|Out-Null}catch{$rejected=$true}
        Check $rejected 'Failed capture was reported as successful.'
        $registry=Get-WsmAssistiveResourceRegistry $workspace
        Check (@($registry.LiveJobs).Count -eq 0 -and @($registry.Materials|Where-Object Closed).Count -eq 0) 'Failed capture lost retention references or leaked an active lock.'
        $space=Get-WsmAvailableBytes (Join-Path $root 'not-created\child')
        Check ($space -is [long] -and $space -gt 0) 'Native caller-volume capacity query failed for a future directory.'
        $rejected=$false;try{Get-WsmAvailableBytes '\\untrusted\share\path'|Out-Null}catch{$rejected=$true}
        Check $rejected 'UNC capacity was guessed from a local drive.'
        Write-Host ('PASS: '+$script:checks+' source producer/material retention/native capacity checks; Server authentication is fixture-isolated.')
    } $root
} finally {if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force}}
