#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-output-flow-'+[Guid]::NewGuid().ToString('N'))
try {
    & $module {
        param($root)
        function Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=('a'*64);Name='fixture';OS='Windows Server';Version='10';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        $enrolled=Initialize-WsmOutputWorkspace $root Source
        $script:flowPackage=[pscustomobject]@{Manifest=[pscustomobject]@{PairId=[Guid]::NewGuid().ToString('D');PlanHash=('b'*64)};Plan=[pscustomobject]@{Source=[pscustomobject]@{HostId=$enrolled.HostId;Fingerprint=('a'*64)}}}
        function Test-WsmMigrationPackage {param($ManifestPath,$ExpectedHash)$script:flowPackage}
        function Export-WsmPackageZip {param($ManifestPath,$ExpectedHash,$OutputDirectory,$VolumeBytes,$CancellationToken)[pscustomobject]@{Kind='TransportBoundaryFixture';Path='fixture-transport.json';SHA256=('d'*64);Mode='Zip';VolumeBytes=$VolumeBytes;OutputDirectory=$OutputDirectory}}
        function Export-WsmDirectoryDelivery {param($ManifestPath,$ExpectedHash,$OutputDirectory,$ReportReferences,$CancellationToken)[pscustomobject]@{Kind='TransportBoundaryFixture';SummaryPath='fixture-summary.json';SummarySHA256=('d'*64);Directory='fixture-delivery';Mode='Directory';OutputDirectory=$OutputDirectory;ReportCount=@($ReportReferences).Count}}
        function Export-WsmDeliveryDocument {param($TransportPath,$ExpectedHash,$ManifestPath,$ExpectedManifestHash,$OutputDirectory,$ReportReferences)[pscustomobject]@{DeliveryId='33333333-3333-4333-8333-333333333333';Path='fixture-receipt.json';SHA256=('e'*64);MarkdownPath='fixture-delivery.md';Status='Sealed';ReadinessProof=$false}}
        $first=Export-WsmEnrolledPackageDelivery $root 'fixture-manifest' ('c'*64)
        if($first.Delivery.Mode -cne 'Zip' -or $first.Delivery.VolumeBytes -ne 536870912 -or -not [IO.File]::Exists($first.IndexPath)){throw 'Enrolled ZIP delivery did not use profile or produce immutable index.'}
        $profilePath=Join-Path $root 'workspace-control\output-profile.json'
        Set-WsmOutputPreferences $root Source (Get-FileHash -LiteralPath $profilePath).Hash Directory | Out-Null
        $new=Export-WsmEnrolledPackageDelivery $root 'fixture-manifest' ('c'*64)
        if($new.Delivery.Mode -cne 'Directory' -or $new.AttemptId -ceq $first.AttemptId){throw 'New directory preference did not create a distinct attempt.'}
        $retry=Export-WsmEnrolledPackageDelivery $root 'fixture-manifest' ('c'*64) -AttemptId $first.AttemptId
        if($retry.Delivery.Mode -cne 'Zip' -or $retry.IndexPath -ceq $first.IndexPath){throw 'Retry altered sealed preferences or overwrote delivery index.'}
        $script:flowPackage.Plan.Source.HostId=[Guid]::NewGuid().ToString('D')
        $blocked=$false;try{Export-WsmEnrolledPackageDelivery $root 'fixture-manifest' ('c'*64) | Out-Null}catch{$blocked=$_.Exception.Message -match 'source differs'}
        if(-not $blocked){throw 'Same-fingerprint wrong source enrollment was accepted.'}
    } $root
    'OutputWorkflow module integration passed (transport native boundary mocked).'
} finally {
    $full=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike 'wsm-output-flow-*'){throw 'Unsafe fixture cleanup path.'}
    if([IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
