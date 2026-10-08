function Export-WsmMigrationSpecBundle {
    param([string]$Workspace,[string]$PairId,[string]$Path,[string]$Category,[string]$Search)
    $c=Get-WsmCatalog $Workspace $PairId;$selected=@(Get-WsmFilteredItems $c $Category $Search Include);$services=@{}
    foreach($i in $c.Items){if($i.Kind -eq 'Service'){$services[$i.NaturalKey]=@()}}
    foreach($i in $c.Items){if($i.Kind -eq 'ServiceRegistryDetails'){$services[$i.NaturalKey]=@();if($i.Settings.PSObject.Properties['DependOnService']){$services[$i.NaturalKey]=@($i.Settings.DependOnService)}}}
    $rows=@(foreach($i in $selected){$spec=$null;if($i.PSObject.Properties['MigrationSpec'] -and $i.MigrationSpec){$spec=$i.MigrationSpec}else{$spec=Get-WsmMigrationSpecDraft $i $c $services};[pscustomobject]@{ItemId=$i.ItemId;SettingsHash=$i.SettingsHash;MigrationSpec=$spec}})
    $bundle=[pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='MigrationSpecBundle';BatchId=$c.BatchId;PairId=$PairId;InventoryRevision=$c.InventoryRevision;DecisionRevision=$c.DecisionRevision;Rows=$rows;DraftOnly=$true}
    Write-WsmJson $Path $bundle;[pscustomobject]@{Path=[IO.Path]::GetFullPath($Path);SHA256=(Get-FileHash -LiteralPath $Path).Hash;Selected=$rows.Count;DraftOnly=$true;Review='Complete per-item fields; removed rows mean no change. Import preview and APPLY-SPECS required.'}
}
function Get-WsmSpecBundlePreviewCore($Catalog,$Bundle,[string]$Hash) {
    Assert-WsmEnvelope $Bundle 'MigrationSpecBundle';Assert-WsmFields $Bundle @('SchemaVersion','ToolVersion','Kind','BatchId','PairId','InventoryRevision','DecisionRevision','Rows','DraftOnly') @('BatchId','PairId','InventoryRevision','DecisionRevision','Rows')
    if($Bundle.BatchId -cne $Catalog.BatchId -or $Bundle.PairId -cne $Catalog.PairId -or $Bundle.InventoryRevision -ne $Catalog.InventoryRevision -or $Bundle.DecisionRevision -ne $Catalog.DecisionRevision){throw (New-WsmContractError 'Spec bundle identity/revision differs; refresh before review.')}
    $index=@{};foreach($i in $Catalog.Items){$index[$i.ItemId]=$i};$seen=@{};$errors=New-Object 'System.Collections.Generic.List[object]';$sample=New-Object 'System.Collections.Generic.List[object]';$count=0;$invalid=0
    foreach($row in $Bundle.Rows){$count++;try{Assert-WsmFields $row @('ItemId','SettingsHash','MigrationSpec') @('ItemId','SettingsHash','MigrationSpec');if($seen.ContainsKey($row.ItemId) -or -not $index.ContainsKey($row.ItemId) -or $index[$row.ItemId].Decision -ne 'Include' -or $row.SettingsHash -cne $index[$row.ItemId].SettingsHash){throw 'Duplicate/unknown/excluded or drifted item.'};$seen[$row.ItemId]=$true;Assert-WsmMigrationSpec $row.MigrationSpec;if($sample.Count -lt 20){$sample.Add([pscustomobject]@{ItemId=$row.ItemId;Name=$index[$row.ItemId].Name;Adapter=$row.MigrationSpec.Adapter;Owner=$row.MigrationSpec.Owner;Evidence=$row.MigrationSpec.Evidence})}}catch{$invalid++;if($errors.Count -lt 100){$errors.Add([pscustomobject]@{Row=$count;Issue=$_.Exception.Message})}}}
    [pscustomobject]@{PairId=$Catalog.PairId;DecisionRevision=$Catalog.DecisionRevision;SHA256=$Hash;Selected=$count;Invalid=$invalid;Blocked=($count -eq 0 -or $invalid -gt 0);Sample=$sample.ToArray();Errors=$errors.ToArray();ErrorsTruncated=($invalid -gt $errors.Count);NoImplicitExclusion=$true}
}
function Get-WsmMigrationSpecBundlePreview {
    param([string]$Workspace,[string]$PairId,[string]$Path,[string]$ExpectedHash)
    Get-WsmSpecBundlePreviewCore (Get-WsmCatalog $Workspace $PairId) (Read-WsmTrustedJson $Path $ExpectedHash) $ExpectedHash
}
function Import-WsmMigrationSpecBundle {
    param([string]$Workspace,[string]$PairId,[string]$Path,[string]$ExpectedHash,[int]$ExpectedRevision,[Parameter(Mandatory)][string]$Acknowledgement)
    if($Acknowledgement -cne 'APPLY-SPECS'){throw (New-WsmContractError 'Batch specs require the preview acknowledgement APPLY-SPECS.')};$bundle=Read-WsmTrustedJson $Path $ExpectedHash
    Invoke-WsmLocked $Workspace {$c=Get-WsmCatalog $Workspace $PairId;if($c.DecisionRevision -ne $ExpectedRevision){throw 'Review changed.'};$preview=Get-WsmSpecBundlePreviewCore $c $bundle $ExpectedHash;if($preview.Blocked){throw (New-WsmContractError 'Spec bundle contains invalid rows; no changes applied.')};$index=@{};foreach($i in $c.Items){$index[$i.ItemId]=$i};foreach($row in $bundle.Rows){$i=$index[$row.ItemId];$i | Add-Member NoteProperty MigrationSpec $row.MigrationSpec -Force;$i.Owner=$row.MigrationSpec.Owner;$i.Evidence=$row.MigrationSpec.Evidence};$c.DecisionRevision++;$c.Approval=$null;$c.History=@($c.History)+@([pscustomobject]@{Action='MigrationSpecBundle';Revision=$c.DecisionRevision;Items=@($bundle.Rows | ForEach-Object ItemId);IndependentHash=$ExpectedHash;Utc=(Get-WsmUtc)});Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c;[pscustomobject]@{Applied=$bundle.Rows.Count;DecisionRevision=$c.DecisionRevision;ApprovalInvalidated=$true}}
}
