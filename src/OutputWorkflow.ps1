function Set-WsmOutputPreferences {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkRoot,[Parameter(Mandatory)][ValidateSet('Source','Manager','Target')][string]$Role,[Parameter(Mandatory)][string]$ExpectedProfileHash,[Parameter(Mandatory)][ValidateSet('Zip','Directory')][string]$Mode,[long]$VolumeBytes=536870912)
    $enrolledOutput=Initialize-WsmOutputWorkspace $WorkRoot $Role
    if($Mode -eq 'Directory'){$VolumeBytes=0}
    Assert-WsmOutputProfileValues ([pscustomobject]@{Mode=$Mode;VolumeBytes=$VolumeBytes})
    $control=Join-Path $enrolledOutput.Profile.WorkRoot 'workspace-control';$path=Join-Path $control 'output-profile.json'
    Invoke-WsmLocked $control {
        $profile=Read-WsmTrustedJson $path $ExpectedProfileHash
        if($profile.ProfileId -cne $enrolledOutput.Profile.ProfileId -or $profile.HostId -cne $enrolledOutput.HostId){throw 'Output enrollment changed while editing transport preferences.'}
        $profile.Mode=$Mode;$profile.VolumeBytes=$VolumeBytes
        Write-WsmJson $path $profile
        [pscustomobject]@{Path=$path;SHA256=((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant());ProfileId=$profile.ProfileId;HostId=$profile.HostId;Mode=$Mode;VolumeBytes=$VolumeBytes;ExistingAttemptsChanged=$false}
    }
}
function Export-WsmEnrolledInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkRoot,[switch]$DeepDiscovery,[string[]]$PortableRoot=@(),[ValidateRange(1,50000)][int]$MaxSoftwareEntries=10000,[string]$ManualEvidencePath,[string]$ManualEvidenceSha256)
    $workspace=Initialize-WsmOutputWorkspace $WorkRoot Source
    Export-WsmInventory -OutputDirectory $workspace.InventoryDirectory -DeepDiscovery:$DeepDiscovery -IncludeSoftwareCatalog -PortableRoot $PortableRoot -MaxSoftwareEntries $MaxSoftwareEntries -ManualEvidencePath $ManualEvidencePath -ManualEvidenceSha256 $ManualEvidenceSha256
}
function Export-WsmEnrolledPackageDelivery {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkRoot,[Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)][string]$ExpectedHash,[string]$AttemptId,[object[]]$ReportReferences=@(),$CancellationToken=$null)
    $package=Test-WsmMigrationPackage $ManifestPath $ExpectedHash
    $enrollment=Initialize-WsmOutputWorkspace $WorkRoot Source
    if($enrollment.Profile.Fingerprint -cne $package.Plan.Source.Fingerprint -or $enrollment.HostId -cne $package.Plan.Source.HostId){throw 'Package source differs from enrolled delivery host.'}
    if($ReportReferences.Count -gt 100){throw 'Delivery report reference budget exceeded.'}
    $documentReferences=@(Assert-WsmDeliveryReportReferences $ReportReferences)
    $safeReferences=@(foreach($reference in $documentReferences){[pscustomobject]@{DocumentId=$reference.DocumentId;Path=$reference.Path;SHA256=$reference.SHA256}})
    $workspace=Resolve-WsmOutputWorkspace -WorkRoot $WorkRoot -Role Source -PairId $package.Manifest.PairId -PlanHash $package.Manifest.PlanHash -AttemptId $AttemptId
    [void](New-WsmOutputOwnedDirectory $workspace.TransportDirectory)
    if($workspace.AttemptProfile.Mode -eq 'Directory'){
        $delivery=Export-WsmDirectoryDelivery -ManifestPath $ManifestPath -ExpectedHash $ExpectedHash -OutputDirectory (Join-Path $workspace.TransportDirectory 'delivery') -ReportReferences $safeReferences -CancellationToken $CancellationToken
    }else{
        $delivery=Export-WsmPackageZip -ManifestPath $ManifestPath -ExpectedHash $ExpectedHash -OutputDirectory $workspace.TransportDirectory -VolumeBytes $workspace.AttemptProfile.VolumeBytes -CancellationToken $CancellationToken
    }
    $documentArguments=@{ExpectedManifestHash=$ExpectedHash;OutputDirectory=(Join-Path $workspace.ReportsDirectory ('delivery-'+[Guid]::NewGuid().ToString('N')));ReportReferences=$ReportReferences}
    [void](New-WsmOutputOwnedDirectory $workspace.TransportDirectory)
    if($workspace.AttemptProfile.Mode -eq 'Directory'){
        $documentArguments.TransportPath=$delivery.SummaryPath;$documentArguments.ExpectedHash=$delivery.SummarySHA256
        $documentArguments.ManifestPath=Join-Path $delivery.Directory 'manifest.json'
    }else{
        $documentArguments.TransportPath=$delivery.Path;$documentArguments.ExpectedHash=$delivery.SHA256;$documentArguments.ManifestPath=$ManifestPath
    }
    $documents=Export-WsmDeliveryDocument @documentArguments
    $indexPath=Join-Path $workspace.TransportDirectory ('delivery-index-'+[Guid]::NewGuid().ToString('D')+'.json')
    Write-WsmJson $indexPath ([pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='DeliveryIndex';DeliveryId=$documents.DeliveryId;AttemptId=$workspace.AttemptId;PairId=$package.Manifest.PairId;PlanHash=$package.Manifest.PlanHash;ManifestHash=$ExpectedHash.ToLowerInvariant();Mode=$workspace.AttemptProfile.Mode;VolumeBytes=$workspace.AttemptProfile.VolumeBytes;ReportReferences=$documentReferences;Delivery=$delivery;DeliveryDocumentation=$documents;CreatedUtc=(Get-WsmUtc);ReadinessProof=$false})
    [pscustomobject]@{Delivery=$delivery;DeliveryDocumentation=$documents;IndexPath=$indexPath;IndexSHA256=(Get-FileHash -LiteralPath $indexPath).Hash.ToLowerInvariant();AttemptId=$workspace.AttemptId;StateDirectory=$workspace.StateDirectory;InventoryDirectory=$workspace.InventoryDirectory;ReadinessProof=$false}
}
