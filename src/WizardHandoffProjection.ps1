# Read-only defaults from closed handoff records; execution always revalidates them.
function Get-WsmWizardTargetHandoffReferences([string]$Workspace,[string]$PairId) {
    $profile=Read-WsmOutputProfile $Workspace
    $empty=[pscustomobject]@{Previews=@();Identity=$null}
    if(-not $profile -or $profile.Role -cne 'Manager' -or -not $PairId){return $empty}
    $catalog=Get-WsmCatalog $Workspace $PairId
    if(-not $catalog.PSObject.Properties['Assistive']){return $empty}
    $toolHash=Get-WsmToolFingerprint;$selectionHash=Get-WsmWizardHandoffSelectionHash $catalog
    $root=Get-WsmWizardHandoffRoot $Workspace;$previews=New-Object 'System.Collections.Generic.List[object]'
    $previewRoot=Join-Path $root 'previews'
    if([IO.Directory]::Exists($previewRoot)){
        Assert-WsmNoReparse $previewRoot
        $directories=@(Get-ChildItem -LiteralPath $previewRoot -Directory)
        if($directories.Count -gt 256){throw 'Too many retained Target handoff previews; select a reviewed material explicitly.'}
        foreach($directory in $directories){
            try{
                Assert-WsmNoReparse $directory.FullName;$path=Join-Path $directory.FullName 'preview.json'
                Assert-WsmNoReparse $path;if((Get-Item -LiteralPath $path).Length -gt 131072){continue};$row=Read-WsmJson $path
                if($row.Kind -cne 'WizardTargetHandoffPreview' -or $row.PairId -cne $PairId -or $row.ManagerHostId -cne $profile.HostId -or $row.ManagerFingerprint -ine $profile.Fingerprint -or $row.ToolFingerprint -ine $toolHash -or $row.SourceInventoryHash -ine $catalog.InventoryHash -or $row.SourceSnapshotHash -ine $catalog.Assistive.SourceSnapshot.SHA256 -or $row.SelectionHash -ine $selectionHash -or [int]$row.ExpectedAssistiveRevision -ne [int]$catalog.Assistive.Revision){continue}
                foreach($entry in @(@($row.ManifestPath,$row.ManifestHash),@($row.IdentityPath,$row.IdentityHash),@($row.InventoryPath,$row.InventoryHash))){Assert-WsmNoReparse $entry[0];if((Get-WsmWizardHandoffHash $entry[0]) -ine $entry[1]){throw 'Received preview bytes changed.'}}
                Assert-WsmId ([string]$row.PreviewId)
                if($directory.Name -cne [string]$row.PreviewId -or $row.TrustMethod -cne 'IndependentManifestHash' -or $row.ExpectedManifestHash -ine $row.ManifestHash){continue}
                foreach($entry in @(@('handoff.json',$row.ManifestHash),@('target-identity.json',$row.IdentityHash),@('target-inventory.json',$row.InventoryHash))){$artifact=Join-Path $directory.FullName $entry[0];Assert-WsmNoReparse $artifact;if((Get-WsmWizardHandoffHash $artifact) -ine $entry[1]){throw 'Preview bytes changed.'}}
                $previews.Add([pscustomobject]@{value=[string]$row.PreviewId;label=('已核對新主機 · '+[string]$row.TargetHostId+' · '+[string]$row.CreatedUtc);manifestHash=[string]$row.ManifestHash;targetFingerprint=[string]$row.TargetFingerprint})
            }catch{continue}
        }
    }
    $identities=@{};$materials=Join-Path $root 'materials'
    if($catalog.Assistive.TargetCurrent -and [IO.Directory]::Exists($materials)){
        Assert-WsmNoReparse $materials;$files=@(Get-ChildItem -LiteralPath $materials -Filter '*.json' -File)
        if($files.Count -gt 512){throw 'Too many retained Target handoff materials; select an independently trusted identity explicitly.'}
        foreach($file in $files){
            try{
                Assert-WsmNoReparse $file.FullName;if($file.Length -gt 131072){continue};$receipt=Read-WsmJson $file.FullName
                if($receipt.Kind -cne 'WizardTargetHandoffImport' -or $receipt.PairId -cne $PairId -or $receipt.ToolFingerprint -ine $toolHash -or $receipt.SourceInventoryHash -ine $catalog.InventoryHash -or $receipt.SourceSnapshotHash -ine $catalog.Assistive.SourceSnapshot.SHA256 -or $receipt.SourceSelectionHash -ine $selectionHash -or $receipt.TargetSnapshotHash -ine $catalog.Assistive.TargetCurrent.SHA256 -or $receipt.TargetHostId -cne $catalog.Assistive.TargetCurrent.HostId -or $receipt.TargetFingerprint -ine $catalog.Assistive.TargetCurrent.Fingerprint -or $receipt.TrustMethod -cne 'IndependentManifestHash'){continue}
                $identityPath=[IO.Path]::GetFullPath([string]$receipt.TargetIdentityPath)
                Assert-WsmAssistivePathUnder $identityPath @($materials) 'Received Target identity' | Out-Null
                Assert-WsmNoReparse $identityPath
                if((Get-WsmWizardHandoffHash $identityPath) -ine [string]$receipt.IdentityHash){continue}
                $identity=Read-WsmTrustedJson $identityPath ([string]$receipt.IdentityHash);Assert-WsmEnvelope $identity 'TargetIdentity'
                if($identity.HostId -cne $receipt.TargetHostId -or $identity.Fingerprint -ine $receipt.TargetFingerprint){continue}
                $identities[[string]$receipt.IdentityHash]=[pscustomobject]@{Path=$identityPath;SHA256=[string]$receipt.IdentityHash;ReceiptPath=$file.FullName;TargetHostId=[string]$identity.HostId;TargetFingerprint=[string]$identity.Fingerprint}
            }catch{continue}
        }
    }
    [pscustomobject]@{Previews=@($previews.ToArray()|Sort-Object value);Identity=$(if($identities.Count -eq 1){@($identities.Values)[0]}else{$null})}
}