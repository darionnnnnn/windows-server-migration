function ConvertTo-WsmAssistiveReportText([object]$Value) {
    if($null -eq $Value){return ''}
    $text=[string]$Value
    if($text -match '(?i)(?:password|passwd|pwd|secret|token|credential|private\s*key)\s*[:=]'){$text='[sensitive value withheld]'}
    [Net.WebUtility]::HtmlEncode($text)
}

function Add-WsmAssistiveReportTable($Lines,[string]$Title,[string[]]$Headers,[object[]]$Rows,[string]$EmptyMessage='No recorded rows.') {
    $Lines.Add('<section><h2>'+[Net.WebUtility]::HtmlEncode($Title)+'</h2>')
    if(-not $Rows -or $Rows.Count -eq 0){$Lines.Add('<p class="empty">'+[Net.WebUtility]::HtmlEncode($EmptyMessage)+'</p></section>');return}
    $Lines.Add('<div class="table-wrap"><table><thead><tr>')
    foreach($header in $Headers){$Lines.Add('<th scope="col">'+[Net.WebUtility]::HtmlEncode($header)+'</th>')}
    $Lines.Add('</tr></thead><tbody>')
    foreach($row in $Rows){
        $Lines.Add('<tr>')
        foreach($cell in @($row)){$Lines.Add('<td>'+ (ConvertTo-WsmAssistiveReportText $cell) +'</td>')}
        $Lines.Add('</tr>')
    }
    $Lines.Add('</tbody></table></div></section>')
}

function Get-WsmAssistiveReportReferencePath([string]$Workspace,$Reference,[string]$Role) {
    Assert-WsmAssistiveReference $Reference $Role
    $root=[IO.Path]::GetFullPath($Workspace).TrimEnd('\')+'\'
    $relative=([string]$Reference.Reference).Replace('/','\')
    $path=[IO.Path]::GetFullPath((Join-Path $Workspace $relative))
    if(-not $path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw ('Assistive '+$Role+' reference escapes the workspace.')}
    Assert-WsmNoReparse $path
    Assert-WsmTrustedFile $path ([string]$Reference.SHA256)
    $path
}

function Add-WsmAssistiveReportEvidenceCopy([string]$EvidenceDirectory,[string]$SourcePath,[string]$ExpectedHash,[string]$Label,[string]$Kind,$IndexRows) {
    Assert-WsmTrustedFile $SourcePath $ExpectedHash
    # The evidence directory is normally made by Export-WsmAssistiveReport. Ensure it
    # still exists at the point of the copy so a caller-side cleanup/race cannot turn
    # the failure into an opaque File.Copy DirectoryNotFoundException.
    if(-not [IO.Directory]::Exists($EvidenceDirectory)){[void][IO.Directory]::CreateDirectory($EvidenceDirectory);Protect-WsmDirectory $EvidenceDirectory}
    # User documents contain references, never raw inventory, XML or payload bytes.
    # The original authority remains in its protected workspace and is not importable
    # through this metadata-only projection.
    $name=$ExpectedHash.ToLowerInvariant()+'.reference.json'
    $destination=Join-Path $EvidenceDirectory $name;Assert-WsmNoReparse $destination
    $projection=[pscustomobject][ordered]@{Kind='ProtectedEvidenceReference';OriginalSHA256=$ExpectedHash.ToLowerInvariant();OriginalBytesIncluded=$false;ImportAuthority=$false}
    if(-not [IO.File]::Exists($destination)){Write-WsmJson $destination $projection}
    else{$existing=Read-WsmJson $destination;if($existing.OriginalSHA256 -ine $ExpectedHash -or $existing.OriginalBytesIncluded -ne $false -or $existing.ImportAuthority -ne $false){throw 'Portable reference collision or tampering detected.'}}
    $projectionHash=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    $IndexRows.Add([pscustomobject]@{Label=$Label;Kind=$Kind;OriginalSHA256=$ExpectedHash.ToLowerInvariant();ProjectionSHA256=$projectionHash;PortablePath=('evidence/'+$name)})
    'evidence/'+$name
}

function Test-WsmAssistiveReport {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)][string]$ExpectedHash)
    if($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'An independently obtained document manifest SHA256 is required.'}
    $manifestFull=[IO.Path]::GetFullPath($ManifestPath);Assert-WsmNoReparse $manifestFull
    if(-not [IO.File]::Exists($manifestFull)){throw 'Document manifest is missing.'}
    $manifestFile=Get-Item -LiteralPath $manifestFull;if($manifestFile.Length -gt 4MB){throw 'Document manifest exceeds the 4 MiB limit.'}
    Assert-WsmTrustedFile $manifestFull $ExpectedHash
    $manifest=Read-WsmJson $manifestFull
    foreach($field in @('SchemaVersion','Kind','DocumentId','PairId','CatalogRevision','AssistiveRevision','SelectionRevision','CatalogHash','SourceSnapshotHash','Members')){if(-not $manifest.PSObject.Properties[$field]){throw ('Document manifest is missing '+$field+'.')}}
    if($manifest.SchemaVersion -ne 1 -or $manifest.Kind -cne 'AssistiveReportDocumentManifest' -or $manifest.Members -isnot [array]){throw 'Unsupported or malformed Assistive report manifest.'}
    if([IO.Path]::GetFileName($manifestFull) -cne 'document-manifest.json'){throw 'Document manifest must use the canonical filename.'}
    Assert-WsmId ([string]$manifest.DocumentId);Assert-WsmId ([string]$manifest.PairId)
    foreach($hash in @($manifest.CatalogHash,$manifest.SourceSnapshotHash)){if([string]$hash -notmatch '^[a-f0-9]{64}$'){throw 'Document manifest contains an invalid authority hash.'}}
    foreach($revision in @($manifest.CatalogRevision,$manifest.AssistiveRevision,$manifest.SelectionRevision)){if(($revision -isnot [int] -and $revision -isnot [long]) -or $revision -lt 1){throw 'Document manifest contains an invalid revision.'}}
    if($manifest.Members.Count -lt 1 -or $manifest.Members.Count -gt 10000){throw 'Document manifest member count is outside supported bounds.'}
    $bundleRoot=[IO.Path]::GetDirectoryName($manifestFull).TrimEnd('\')+'\';$seen=@{};$totalBytes=[long]0;$required=@{'index.html'=$false}
    foreach($member in $manifest.Members){
        foreach($field in @('Path','Bytes','ProjectionSHA256','OriginalSHA256')){if(-not $member.PSObject.Properties[$field]){throw 'Document manifest member is incomplete.'}}
        $relative=[string]$member.Path
        if([string]::IsNullOrWhiteSpace($relative) -or $relative.Contains('\') -or [IO.Path]::IsPathRooted($relative) -or $relative -match '[:\x00-\x1f<>"|?*]' -or $relative.EndsWith('/')){throw 'Unsafe document manifest member path.'}
        foreach($part in $relative.Split('/')){if([string]::IsNullOrWhiteSpace($part) -or $part -in @('.','..') -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){throw 'Unsafe document manifest member path.'}}
        $key=$relative.ToLowerInvariant();if($seen.ContainsKey($key)){throw 'Duplicate document manifest member path.'};$seen[$key]=$true
        if($relative -ieq 'index.html'){$required['index.html']=$true}
        if($relative -ieq 'document-manifest.json'){throw 'Document manifest cannot list itself as a content member.'}
        if(($member.Bytes -isnot [int] -and $member.Bytes -isnot [long]) -or $member.Bytes -lt 0 -or $member.Bytes -gt 64MB){throw 'Document member exceeds its 64 MiB size bound.'}
        $totalBytes += [long]$member.Bytes;if($totalBytes -gt 256MB){throw 'Document bundle exceeds its 256 MiB size bound.'}
        if([string]$member.ProjectionSHA256 -notmatch '^[a-f0-9]{64}$' -or ([string]$member.OriginalSHA256 -and [string]$member.OriginalSHA256 -notmatch '^[a-f0-9]{64}$')){throw 'Document member contains an invalid hash.'}
        $path=Join-Path $bundleRoot $relative;Assert-WsmNoReparse $path
        if(-not [IO.File]::Exists($path)){throw ('Document bundle member is missing: '+$relative)}
        $file=Get-Item -LiteralPath $path;if($file.Length -ne [long]$member.Bytes){throw ('Document member byte count changed: '+$relative)}
        Assert-WsmTrustedFile $path ([string]$member.ProjectionSHA256)
    }
    if(-not $required['index.html']){throw 'Document bundle is missing the required index.html page.'}
    $actual=@{};$pending=New-Object 'System.Collections.Generic.Stack[string]';$pending.Push($bundleRoot.TrimEnd('\'))
    while($pending.Count -gt 0){$directory=$pending.Pop();Assert-WsmNoReparse $directory;foreach($entry in @(Get-ChildItem -LiteralPath $directory -Force)){Assert-WsmNoReparse $entry.FullName;if($entry.PSIsContainer){$pending.Push($entry.FullName)}elseif([IO.Path]::GetFullPath($entry.FullName) -ine $manifestFull){$relative=$entry.FullName.Substring($bundleRoot.Length).Replace('\','/');$actual[$relative.ToLowerInvariant()]=$relative}}}
    if($actual.Count -ne $seen.Count){throw 'Document bundle has unmanifested or missing files.'}
    foreach($key in $seen.Keys){if(-not $actual.ContainsKey($key)){throw 'Document manifest does not describe the complete bundle.'}}
    [pscustomobject][ordered]@{Valid=$true;DocumentId=[string]$manifest.DocumentId;PairId=[string]$manifest.PairId;MemberCount=$manifest.Members.Count;TotalBytes=$totalBytes;ManifestHash=$ExpectedHash.ToLowerInvariant();CatalogHash=[string]$manifest.CatalogHash;SourceSnapshotHash=[string]$manifest.SourceSnapshotHash;ImportAuthority=$false;RestoreAuthority=$false}
}

function Get-WsmAssistiveReportComparisonIsCurrent($Catalog) {
    $comparison=$Catalog.Assistive.Comparison
    if($null -eq $comparison){return $false}
    if($comparison.SourceSnapshotHash -ine $Catalog.Assistive.SourceSnapshot.SHA256 -or $comparison.SelectionRevision -ne $Catalog.Assistive.Selections.Revision -or -not $Catalog.Assistive.TargetCurrent -or $comparison.TargetSnapshotHash -ine $Catalog.Assistive.TargetCurrent.SHA256){return $false}
    return $true
}

function Get-WsmAssistiveReportInventorySoftware($Inventory,[string]$Label) {
    if(-not $Inventory.PSObject.Properties['SoftwareCatalog'] -or -not $Inventory.SoftwareCatalog){return ,@()}
    $catalog=$Inventory.SoftwareCatalog
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($entry in @($catalog.Entries)){
        $rows.Add([object[]]@($Label,[string]$entry.Name,[string]$entry.Publisher,[string]$entry.Version,[string]$entry.Architecture,[string]$entry.Scope,[string]$entry.AccountContext,[string]$entry.Location,[string]$entry.CaptureStatus))
    }
    foreach($coverage in @($catalog.Coverage)){
        if([string]$coverage.Status -notin @('Success','NotInstalled')){$rows.Add([object[]]@($Label,('Coverage: '+[string]$coverage.Probe),'','','','','','',[string]$coverage.Status))}
    }
    ,$rows.ToArray()
}

function Get-WsmAssistiveReportPathRows($Catalog) {
    $rows=New-Object 'System.Collections.Generic.List[object]'
    $itemsById=@{};foreach($item in @($Catalog.Items)){$itemsById[[string]$item.ItemId]=$item}
    foreach($item in @($Catalog.Items)){
        $selected=$false;$selection=@((Get-WsmAssistiveCurrentSelections $Catalog).Items | Where-Object ItemId -CEQ $item.ItemId);if($selection.Count -eq 1){$selected=[bool]$selection[0].Selected}
        if($item.PSObject.Properties['MigrationSpec'] -and $item.MigrationSpec -and $item.MigrationSpec.Adapter -eq 'FileScope'){
            $spec=$item.MigrationSpec
            $rows.Add([object[]]@([string]$item.Name,[string]$item.ItemId,$selected,[string]$item.Decision,[string]$spec.TransferChannel,'FileScope root',[string]$spec.SourcePath,[string]$spec.TargetPath,'','',$(if($spec.ContentSelection){[string]$spec.ContentSelection}else{'Not recorded'})))
            foreach($entry in @($spec.ConfigFiles)){$source='';$target='';if($spec.SourcePath){$source=Join-Path ([string]$spec.SourcePath) ([string]$entry.RelativePath)};if($spec.TargetPath){$target=Join-Path ([string]$spec.TargetPath) ([string]$entry.RelativePath)};$rows.Add([object[]]@([string]$item.Name,[string]$item.ItemId,$selected,[string]$item.Decision,[string]$spec.TransferChannel,'Approved file',[string]$source,[string]$target,[string]$entry.RelativePath,[string]$entry.SHA256,'ConfigFiles whitelist'))}
        }
        if($item.PSObject.Properties['MigrationSpec'] -and $item.MigrationSpec -and $item.MigrationSpec.PSObject.Properties['WorkloadMappingReview']){
            foreach($mapping in @($item.MigrationSpec.WorkloadMappingReview)){$rows.Add([object[]]@([string]$item.Name,[string]$item.ItemId,$selected,[string]$item.Decision,'Workload reference',[string]$mapping.ReferenceKind,[string]$mapping.OldRawValue,[string]$mapping.TargetValue,[string]$mapping.FieldPointer,[string]$mapping.Status,[string]$mapping.Reason))}
        }
    }
    if($Catalog.PSObject.Properties['WorkloadDiscovery'] -and $Catalog.WorkloadDiscovery){
        foreach($reference in @($Catalog.WorkloadDiscovery.References)){
            $consumer=@($Catalog.Items | Where-Object ItemId -CEQ $reference.ConsumerItemId);$name='';$selected=$false;$decision='Unknown';if($consumer.Count){$name=[string]$consumer[0].Name;$decision=[string]$consumer[0].Decision;$select=@((Get-WsmAssistiveCurrentSelections $Catalog).Items | Where-Object ItemId -CEQ $reference.ConsumerItemId);if($select.Count){$selected=[bool]$select[0].Selected}}
            $mapped='';$status=[string]$reference.Reason;$field='';if($consumer.Count -and $consumer[0].PSObject.Properties['MigrationSpec'] -and $consumer[0].MigrationSpec.PSObject.Properties['WorkloadMappingReview']){$maps=@($consumer[0].MigrationSpec.WorkloadMappingReview | Where-Object {$_.FieldPointer -ceq $reference.FieldPointer -and $_.ReferenceKind -ceq $reference.ReferenceKind});if($maps.Count -eq 1){$mapped=[string]$maps[0].TargetValue;$status=[string]$maps[0].Status;$field=[string]$maps[0].FieldPointer}}
            if(-not $field){$field=[string]$reference.FieldPointer}
            $original=[string]$reference.RawValue;if(-not $original -or $original -match '^(?i)(?:\[.*withheld.*\]|unknown|notapplicable)$'){$original=[string]$reference.ResolvedPath}
            $rows.Add([object[]]@($name,[string]$reference.ConsumerItemId,$selected,$decision,[string]$reference.Channel,[string]$reference.ReferenceKind,$original,$mapped,$field,$status,$reference.ReviewRequired))
        }
    }
    ,$rows.ToArray()
}

function Get-WsmAssistiveReportManualRows($Catalog) {
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($item in @($Catalog.Items)){
        $selection=@((Get-WsmAssistiveCurrentSelections $Catalog).Items | Where-Object ItemId -CEQ $item.ItemId);$selected=$false;if($selection.Count){$selected=[bool]$selection[0].Selected}
        if(-not $selected){continue}
        $adapter='';$owner=[string]$item.Owner;$reason=[string]$item.Reason;$status=[string]$item.Status;$action='Review required';if($item.PSObject.Properties['MigrationSpec'] -and $item.MigrationSpec){$adapter=[string]$item.MigrationSpec.Adapter;if($item.MigrationSpec.PSObject.Properties['Owner']){$owner=[string]$item.MigrationSpec.Owner};if($item.MigrationSpec.PSObject.Properties['Evidence']){$reason=[string]$item.MigrationSpec.Evidence};if($adapter -ceq 'ManualWorkflow'){$action='ManualWorkflow';$reason=[string]$item.MigrationSpec.Procedure}elseif($item.MigrationSpec.PSObject.Properties['WorkloadMappingReview'] -and @($item.MigrationSpec.WorkloadMappingReview | Where-Object {$_.ReviewRequired -or -not $_.Applied}).Count){$action='Unresolved workload mapping'}elseif($item.Status -eq 'Success'){$action='Spec reviewed; execution remains separately recorded'}}
        if($item.Decision -ceq 'Pending'){$action='Review decision pending'}elseif($item.Decision -ceq 'Exclude'){$action='Selected but excluded; reconcile selection and decision'}
        $rows.Add([object[]]@([string]$item.Name,[string]$item.ItemId,$adapter,$status,[string]$item.Decision,$owner,$action,$reason))
        if($item.PSObject.Properties['MigrationSpec'] -and $item.MigrationSpec -and $item.MigrationSpec.PSObject.Properties['SharedResourceImpacts']){foreach($impact in @($item.MigrationSpec.SharedResourceImpacts)){$impactAction='Shared resource impact recorded';if($impact.RequiresSharedReview){$impactAction='Shared resource review required'};$consumers=@($impact.ConsumerItemIds) -join ', ';$selectedConsumers=@($impact.SelectedConsumerItemIds) -join ', ';$unselectedConsumers=@($impact.UnselectedConsumerItemIds) -join ', ';$impactReason=[string]$impact.OwnerReviewReason;$detail=('Resource='+[string]$impact.ResourceKind+'/'+[string]$impact.ResourceItemId+'; consumers='+$consumers+'; selected='+$selectedConsumers+'; unselected='+$unselectedConsumers);if($impactReason){$detail+='; owner review='+$impactReason};$rows.Add([object[]]@([string]$item.Name,[string]$item.ItemId,$adapter,'SharedResourceImpact',[string]$item.Decision,$owner,$impactAction,$detail))}}
    }
    ,$rows.ToArray()
}

function Get-WsmAssistiveReportResultRows([string]$Workspace,$Catalog) {
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($reference in @($Catalog.Assistive.ResultReferences)){
        $path=Get-WsmAssistiveReportReferencePath $Workspace $reference 'Result'
        $kind='';if($reference.PSObject.Properties['Kind']){$kind=[string]$reference.Kind}
        $status='Imported evidence; lifecycle meaning not inferred';$details='';$count=''
        if($kind -ceq 'AssistiveNonCTransferResult'){
            $result=Read-WsmTrustedJson $path ([string]$reference.SHA256)
            $counts=@{};foreach($row in @($result.Rows)){if(-not $counts.ContainsKey([string]$row.Status)){$counts[[string]$row.Status]=0};$counts[[string]$row.Status]++}
            $details=(@($counts.Keys | Sort-Object | ForEach-Object {$_+': '+$counts[$_]} ) -join '; ');$count=@($result.Rows).Count;$status='Non-C transfer evidence; manual ownership remains unless separately accepted'
        }elseif($kind -ceq 'AssistiveEnvironmentProbe'){
            $probe=Read-WsmTrustedJson $path ([string]$reference.SHA256);$count=@($probe.Checks).Count;$status='Read-only environment observations';$details='PASS: '+@($probe.Checks|Where-Object Status -EQ PASS).Count+'; NotTested: '+@($probe.Checks|Where-Object Status -EQ NotTested).Count+'; qualification/business validation: false'
        }elseif($reference.PSObject.Properties['Applied'] -or $reference.PSObject.Properties['BlockedConflict'] -or $reference.PSObject.Properties['DeferredManual']){
            $status='Imported result summary';$details='Applied: '+[string]$reference.Applied+'; BlockedConflict: '+[string]$reference.BlockedConflict+'; DeferredManual: '+[string]$reference.DeferredManual
        }
        $rows.Add([object[]]@($kind,[string]$reference.CreatedUtc,$status,$count,$details,[string]$reference.SHA256))
    }
    ,$rows.ToArray()
}

function Get-WsmAssistiveReportStageResults($Catalog) {
    if(-not $Catalog.PSObject.Properties['StageResults'] -or -not $Catalog.StageResults){return [pscustomobject]@{Latest=$null;Rows=@();AllCurrent=@()}}
    if(-not (Get-Command Test-WsmStageResultCurrent -CommandType Function -ErrorAction SilentlyContinue)){throw 'Current stage-result validation is unavailable; the report cannot project imported results.'}
    $current=@($Catalog.StageResults | Where-Object {Test-WsmStageResultCurrent $Catalog $_})
    if(-not $current.Count){return [pscustomobject]@{Latest=$null;Rows=@();AllCurrent=@()}}
    $latest=$current | Sort-Object @{Expression={if($_.PSObject.Properties['PayloadGeneration']){[long]$_.PayloadGeneration}else{0}};Descending=$true},@{Expression={[DateTimeOffset]::Parse($_.ProducedUtc)};Descending=$true},@{Expression={[long]$_.Sequence};Descending=$true} | Select-Object -First 1
    $itemIndex=@{};foreach($item in @($Catalog.Items)){$itemIndex[[string]$item.ItemId]=$item}
    $rows=New-Object 'System.Collections.Generic.List[object]'
    if($latest.PSObject.Properties['Assistive'] -and $latest.Assistive.PSObject.Properties['ItemResults']){
        foreach($result in @($latest.Assistive.ItemResults)){$name=[string]$result.ItemId;$decision=[string]$result.Decision;if($itemIndex.ContainsKey([string]$result.ItemId)){$name=[string]$itemIndex[[string]$result.ItemId].Name};$rows.Add([object[]]@($name,[string]$result.ItemId,[string]$latest.Stage,[string]$result.Status,[string]$latest.Status,[string]$latest.PayloadGeneration,[string]$latest.ManifestHash,[string]$result.AppliedManifestHash,[string]$result.AppliedGeneration,[string]$result.Pending,[string]$result.Deferred))}
    }
    [pscustomobject]@{Latest=$latest;Rows=$rows.ToArray();AllCurrent=$current}
}

function Get-WsmAssistiveReportFileResultRows($StageProjection,$Catalog) {
    $rows=New-Object 'System.Collections.Generic.List[object]'
    if(-not $StageProjection.Latest -or -not $StageProjection.Latest.Assistive -or -not $StageProjection.Latest.Assistive.PSObject.Properties['FileResults']){return ,$rows.ToArray()}
    $items=@{};foreach($item in @($Catalog.Items)){$items[[string]$item.ItemId]=$item}
    foreach($file in @($StageProjection.Latest.Assistive.FileResults)){
        $name=[string]$file.ItemId;if($items.ContainsKey([string]$file.ItemId)){$name=[string]$items[[string]$file.ItemId].Name}
        $rows.Add([object[]]@($name,[string]$file.ItemId,[string]$file.Channel,[string]$file.RelativePath,[string]$file.OriginalPath,[string]$file.PreservedPath,[string]$file.EffectivePath,[string]$file.Status,[string]$file.ExistingTargetPath,[string]$file.ExistingTargetHash,[string]$file.SourceHash,[string]$file.ObservedHash,[string]$file.Reason,[string]$file.EntryId,[string]$file.Generation,[string]$file.ProjectedGeneration))
    }
    ,$rows.ToArray()
}

function Get-WsmAssistiveReportCountRows($Catalog,$StageProjection,$StageFileRows) {
    $selection=Get-WsmAssistiveCurrentSelections $Catalog
    $selectionById=@{};foreach($entry in @($selection.Items)){$selectionById[[string]$entry.ItemId]=[bool]$entry.Selected}
    $stageById=@{};$latest=$StageProjection.Latest;$stageItemsKnown=($latest -and $latest.Assistive -and $latest.Assistive.PSObject.Properties['ItemResults'])
    if($stageItemsKnown){foreach($result in @($latest.Assistive.ItemResults)){$stageById[[string]$result.ItemId]=$result}}
    $channels=@{}
    foreach($item in @($Catalog.Items)){
        $channel='Unclassified'
        if($item.PSObject.Properties['MigrationSpec'] -and $item.MigrationSpec -and $item.MigrationSpec.PSObject.Properties['TransferChannel'] -and $item.MigrationSpec.TransferChannel){$channel=[string]$item.MigrationSpec.TransferChannel}
        if(-not $channels.ContainsKey($channel)){$channels[$channel]=[pscustomobject]@{Discovered=0;Selected=0;Approved=0;StageObjects=0;Manual=0;Pending=0;Deferred=0}}
        $counts=$channels[$channel];$counts.Discovered++
        $selected=$selectionById.ContainsKey([string]$item.ItemId) -and $selectionById[[string]$item.ItemId]
        if($selected){$counts.Selected++;if([string]$item.Decision -ceq 'Include'){$counts.Approved++};if($item.PSObject.Properties['MigrationSpec'] -and $item.MigrationSpec -and [string]$item.MigrationSpec.Adapter -ceq 'ManualWorkflow'){$counts.Manual++}}
        if($stageById.ContainsKey([string]$item.ItemId)){$counts.StageObjects++;$result=$stageById[[string]$item.ItemId];if([bool]$result.Pending){$counts.Pending++};if([bool]$result.Deferred){$counts.Deferred++}}
    }
    $fileExpansionKnown=($latest -and $latest.Assistive -and $latest.Assistive.PSObject.Properties['FileResults'])
    $fileByChannel=@{C=0;NonC=0};$placementsByChannel=@{C=0;NonC=0};$conflicts=0
    if($fileExpansionKnown){foreach($file in @($latest.Assistive.FileResults)){$channel=[string]$file.Channel;if(-not $fileByChannel.ContainsKey($channel)){$fileByChannel[$channel]=0;$placementsByChannel[$channel]=0};$fileByChannel[$channel]++;if([string]$file.Status -ceq 'BlockedConflict'){$conflicts++};if([string]$file.EffectivePath -and [string]$file.Status -ceq 'Applied'){$placementsByChannel[$channel]++}}}
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($channel in @($channels.Keys | Sort-Object)){$c=$channels[$channel];$pendingCount=$c.Pending;$deferredCount=$c.Deferred;if(-not $stageItemsKnown){$pendingCount='Unknown';$deferredCount='Unknown'};$rows.Add([object[]]@('Discovery / current selection',$channel,$c.Discovered,$c.Selected,$c.Approved,$c.StageObjects,$c.Manual,$pendingCount,$deferredCount,'NotTested','Unknown','Unknown'))}
    if(-not $channels.ContainsKey('C')){$channels['C']=[pscustomobject]@{Discovered=0;Selected=0;Approved=0;StageObjects=0;Manual=0;Pending=0;Deferred=0}}
    if(-not $channels.ContainsKey('NonC')){$channels['NonC']=[pscustomobject]@{Discovered=0;Selected=0;Approved=0;StageObjects=0;Manual=0;Pending=0;Deferred=0}}
    foreach($channel in @('C','NonC')){
        $c=$channels[$channel];$fileCount='Unknown';$placementCount='Unknown';if($fileExpansionKnown){$fileCount=[int]$fileByChannel[$channel];$placementCount=[int]$placementsByChannel[$channel]};$pendingCount=$c.Pending;$deferredCount=$c.Deferred;if(-not $stageItemsKnown){$pendingCount='Unknown';$deferredCount='Unknown'}
        $rows.Add([object[]]@('Accepted execution results',$channel,$c.Discovered,$c.Selected,$c.Approved,$c.StageObjects,$c.Manual,$pendingCount,$deferredCount,'NotTested',$fileCount,$placementCount))
    }
    $totalItems=@($Catalog.Items).Count;$selectedTotal=@($selection.Items | Where-Object Selected).Count;$approvedTotal=@($Catalog.Items | Where-Object {$_.Decision -ceq 'Include' -and $selectionById.ContainsKey([string]$_.ItemId) -and $selectionById[[string]$_.ItemId]}).Count
    $excluded=@($Catalog.Items | Where-Object Decision -CEQ Exclude).Count;$unsupported=@($Catalog.Items | Where-Object Status -CEQ Unsupported).Count
    $resultObjects=@($stageById.Keys).Count;$manualPending=0
    foreach($item in @($Catalog.Items)){$hasManualSpec=$item.PSObject.Properties['MigrationSpec'] -and $item.MigrationSpec -and $item.MigrationSpec.PSObject.Properties['Adapter'] -and [string]$item.MigrationSpec.Adapter -ceq 'ManualWorkflow';$selected=$selectionById.ContainsKey([string]$item.ItemId) -and $selectionById[[string]$item.ItemId];$isPending=(-not $stageById.ContainsKey([string]$item.ItemId));if($stageById.ContainsKey([string]$item.ItemId)){$manualResult=$stageById[[string]$item.ItemId];$isPending=[bool]$manualResult.Pending -or [bool]$manualResult.Deferred -or [string]$manualResult.Status -ceq 'ManualEvidenceRequired'};if($hasManualSpec -and $selected -and $isPending){$manualPending++}}
    $pendingTotal=0;$deferredTotal=0;foreach($result in @($stageById.Values)){if([bool]$result.Pending){$pendingTotal++};if([bool]$result.Deferred){$deferredTotal++}}
    if(-not $stageItemsKnown){$pendingTotal='Unknown';$deferredTotal='Unknown'};$conflictTotal=$conflicts;if(-not $fileExpansionKnown){$conflictTotal='Unknown'}
    [pscustomobject][ordered]@{Rows=$rows.ToArray();Totals=[pscustomobject][ordered]@{Discovered=$totalItems;Selected=$selectedTotal;ApprovedSelected=$approvedTotal;Excluded=$excluded;Unsupported=$unsupported;AcceptedStageObjects=$resultObjects;ManualPending=$manualPending;Pending=$pendingTotal;Deferred=$deferredTotal;OwnershipConflicts=$conflictTotal;Availability='NotTested';FileExpansion=$(if($fileExpansionKnown){'Accepted FileResults rows only; approved source file denominator is Unknown'}else{'Unknown: no current accepted FileResults expansion'})}}
}

function Export-WsmAssistiveReport {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$OutputDirectory)
    Assert-WsmId $PairId
    $workspaceFull=[IO.Path]::GetFullPath($Workspace);Assert-WsmNoReparse $workspaceFull
    $outputFull=[IO.Path]::GetFullPath($OutputDirectory);Assert-WsmNoReparse $outputFull
    $catalog=Get-WsmCatalog $workspaceFull $PairId
    if($catalog.SchemaVersion -ne 3 -or -not $catalog.PSObject.Properties['Assistive']){throw 'Assistive report requires an explicitly enabled schema 3 catalog.'}
    Assert-WsmAssistiveContract $catalog Catalog | Out-Null
    Assert-WsmAssistiveWorkspaceReferences $workspaceFull $catalog | Out-Null
    $catalogPath=Get-WsmCatalogPath $workspaceFull $PairId;Assert-WsmNoReparse $catalogPath
    $catalogHash=(Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $stamp=[DateTime]::UtcNow.ToString('yyyyMMddHHmmss',[Globalization.CultureInfo]::InvariantCulture)
    if(-not [IO.Directory]::Exists($outputFull)){[void][IO.Directory]::CreateDirectory($outputFull);Protect-WsmDirectory $outputFull}
    # Keep the full path below the legacy Windows PowerShell MAX_PATH boundary;
    # content-addressed evidence filenames are intentionally long.
    $bundle=Join-Path $outputFull ('wsm-a-'+$PairId.Substring(0,8)+'-'+$stamp+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
    if([IO.Directory]::Exists($bundle) -or [IO.File]::Exists($bundle)){throw 'Report bundle destination collision; retry with a new output directory.'}
    [void][IO.Directory]::CreateDirectory($bundle);Protect-WsmDirectory $bundle;Assert-WsmNoReparse $bundle
    $evidenceDirectory=Join-Path $bundle 'evidence';[void][IO.Directory]::CreateDirectory($evidenceDirectory);Protect-WsmDirectory $evidenceDirectory
    $indexRows=New-Object 'System.Collections.Generic.List[object]'
    try {
        $null=Add-WsmAssistiveReportEvidenceCopy $evidenceDirectory $catalogPath $catalogHash 'Manager catalog snapshot' 'AssistiveCatalog' $indexRows
        $refs=New-Object 'System.Collections.Generic.List[object]'
        $refs.Add([pscustomobject]@{Label='Immutable source inventory';Kind='SourceSnapshot';Reference=$catalog.Assistive.SourceSnapshot})
        if($catalog.Assistive.TargetBaseline){$refs.Add([pscustomobject]@{Label='First observed target baseline';Kind='TargetBaseline';Reference=$catalog.Assistive.TargetBaseline})}
        if($catalog.Assistive.TargetCurrent){$refs.Add([pscustomobject]@{Label='Current target inventory';Kind='TargetCurrent';Reference=$catalog.Assistive.TargetCurrent})}
        foreach($reference in @($catalog.Assistive.MaterialReferences)){$kind='Material';if($reference.PSObject.Properties['Kind']){$kind=[string]$reference.Kind};$refs.Add([pscustomobject]@{Label='Protected material';Kind=$kind;Reference=$reference})}
        foreach($reference in @($catalog.Assistive.ResultReferences)){$kind='Result';if($reference.PSObject.Properties['Kind']){$kind=[string]$reference.Kind};$refs.Add([pscustomobject]@{Label='Imported result';Kind=$kind;Reference=$reference})}
        $portableByHash=@{}
        foreach($entry in $refs){$ref=$entry.Reference;$path=Get-WsmAssistiveReportReferencePath $workspaceFull $ref $entry.Label;$hash=[string]$ref.SHA256;$portable='';if($portableByHash.ContainsKey($hash)){$portable=$portableByHash[$hash]}else{$portable=Add-WsmAssistiveReportEvidenceCopy $evidenceDirectory $path $hash ([string]$entry.Label) ([string]$entry.Kind) $indexRows;$portableByHash[$hash]=$portable};$entry | Add-Member NoteProperty _ProtectedPath $path;$entry | Add-Member NoteProperty PortablePath $portable}
        $sourceInventory=Read-WsmTrustedJson (Get-WsmAssistiveReportReferencePath $workspaceFull $catalog.Assistive.SourceSnapshot 'Source snapshot') ([string]$catalog.Assistive.SourceSnapshot.SHA256)
        $baselineInventory=$null;if($catalog.Assistive.TargetBaseline){$baselineInventory=Read-WsmTrustedJson (Get-WsmAssistiveReportReferencePath $workspaceFull $catalog.Assistive.TargetBaseline 'Target baseline') ([string]$catalog.Assistive.TargetBaseline.SHA256)}
        $currentInventory=$null;if($catalog.Assistive.TargetCurrent){$currentInventory=Read-WsmTrustedJson (Get-WsmAssistiveReportReferencePath $workspaceFull $catalog.Assistive.TargetCurrent 'Target current') ([string]$catalog.Assistive.TargetCurrent.SHA256)}
        $catalogHashAfter=(Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant();if($catalogHashAfter -ine $catalogHash){throw 'Catalog changed while the report was being assembled; keep the evidence and rerun from a stable revision.'}

        $lines=New-Object 'System.Collections.Generic.List[string]'
        $lines.Add('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>EOS Assistive migration report</title><style>')
        $lines.Add(':root{color-scheme:light;--ink:#182b3a;--muted:#536778;--line:#ced8e0;--panel:#f4f7f9;--accent:#145a78;--warn:#7b4a00;--bad:#862c2c}*{box-sizing:border-box}body{margin:0;background:#eef2f5;color:var(--ink);font:16px/1.55 Segoe UI,Arial,sans-serif}main{max-width:1240px;margin:0 auto;padding:28px 22px 70px}header,.notice,section{background:#fff;border:1px solid var(--line);border-radius:10px;margin:0 0 18px;padding:20px}h1{font-size:2rem;margin:0 0 4px}h2{font-size:1.25rem;margin:0 0 14px}h3{font-size:1rem;margin:18px 0 8px}.subtitle,.muted,.empty{color:var(--muted)}.notice{border-left:5px solid var(--warn);background:#fffaf0}.badge{display:inline-block;border:1px solid var(--line);background:var(--panel);border-radius:999px;padding:3px 10px;margin:5px 5px 0 0;font-size:.9rem}.table-wrap{overflow:auto}table{border-collapse:collapse;width:100%;min-width:720px}th,td{border-bottom:1px solid var(--line);padding:9px 10px;text-align:left;vertical-align:top;overflow-wrap:anywhere}th{background:var(--panel);position:sticky;top:0}code,.hash{font:12px Consolas,monospace;overflow-wrap:anywhere}a{color:var(--accent)}.small{font-size:.9rem}.foot{color:var(--muted);font-size:.9rem;border-top:1px solid var(--line);padding-top:14px}</style></head><body><main>')
        $lines.Add('<header><h1>EOS Assistive migration report</h1><p class="subtitle">Read-only report generated '+(ConvertTo-WsmAssistiveReportText (Get-WsmUtc))+'. Pair '+(ConvertTo-WsmAssistiveReportText $PairId)+'. Catalog revision '+(ConvertTo-WsmAssistiveReportText $catalog.DecisionRevision)+'.</p><p><span class="badge">Schema 3</span><span class="badge">'+(ConvertTo-WsmAssistiveReportText $catalog.Source.Name)+' → '+(ConvertTo-WsmAssistiveReportText $catalog.TargetName)+'</span><span class="badge">Report is not an approval or business acceptance</span></p></header>')
        $lines.Add('<div class="notice"><strong>Evidence and status boundary.</strong> The report links metadata-only references whose original SHA256 values identify protected workspace evidence. Raw inventory JSON, XML, full configuration settings, credentials, secrets and private keys are not copied into this document bundle. Source observations, selected intent, migration approval, target execution, readback and business acceptance are separate states. A missing or unattached result is shown as unknown or not recorded.</div>')
        $approvalState='No current sealed approval record';$approvalHash='';$approvalTarget='';$approvalUtc='';if($catalog.Approval){$approvalState='Approval record present; external sealed plan bytes are not attached to this workspace report';$approvalHash=[string]$catalog.Approval.Hash;$approvalTarget=[string]$catalog.Approval.TargetFingerprint;$approvalUtc=[string]$catalog.Approval.Utc}
        $comparisonState='No saved current comparison';if(Get-WsmAssistiveReportComparisonIsCurrent $catalog){$comparisonState='Saved comparison is bound to current source/target hashes and selection revision '+[string]$catalog.Assistive.Comparison.Revision}elseif($catalog.Assistive.Comparison){$comparisonState='Saved comparison is stale; it is not presented as current'}
        $stateRows=@([object[]]@('Source snapshot',[string]$catalog.Assistive.SourceSnapshot.InventoryRevision,[string]$catalog.Assistive.SourceSnapshot.SHA256,[string]$catalog.Source.Fingerprint,'Immutable source discovery'),[object[]]@('Target baseline',$(if($catalog.Assistive.TargetBaseline){[string]$catalog.Assistive.TargetBaseline.InventoryRevision}else{'Not recorded'}),$(if($catalog.Assistive.TargetBaseline){[string]$catalog.Assistive.TargetBaseline.SHA256}else{''}),$(if($catalog.Assistive.TargetBaseline){[string]$catalog.Assistive.TargetBaseline.Fingerprint}else{''}),$(if($catalog.Assistive.TargetBaseline -and $catalog.Assistive.TargetBaseline.PSObject.Properties['BaselineKind']){[string]$catalog.Assistive.TargetBaseline.BaselineKind}else{'FirstObserved only when recorded'})),[object[]]@('Target current',$(if($catalog.Assistive.TargetCurrent){[string]$catalog.Assistive.TargetCurrent.InventoryRevision}else{'Not recorded'}),$(if($catalog.Assistive.TargetCurrent){[string]$catalog.Assistive.TargetCurrent.SHA256}else{''}),$(if($catalog.Assistive.TargetCurrent){[string]$catalog.Assistive.TargetCurrent.Fingerprint}else{''}),'Latest imported observation'),[object[]]@('Approval',$approvalState,$approvalHash,$approvalTarget,$approvalUtc),[object[]]@('Software comparison',$comparisonState,'','','Source/chosen/observed versions are not compatibility proof'))
        Add-WsmAssistiveReportTable $lines 'Pair, snapshot and approval state' @('Record','Revision','SHA256 / value','Host fingerprint','Meaning / timestamp') $stateRows 'Only source snapshot and current catalog authority are available.'

        $selectionRows=New-Object 'System.Collections.Generic.List[object]';$selectionIndex=@{};foreach($s in @((Get-WsmAssistiveCurrentSelections $catalog).Items)){$selectionIndex[[string]$s.ItemId]=$s}
        foreach($item in @($catalog.Items)){$selected='Unknown';$why='';if($selectionIndex.ContainsKey([string]$item.ItemId)){$selected=[string]$selectionIndex[[string]$item.ItemId].Selected;$why=[string]$selectionIndex[[string]$item.ItemId].Reason};$spec='';if($item.PSObject.Properties['MigrationSpec'] -and $item.MigrationSpec){$spec=[string]$item.MigrationSpec.Adapter};$selectionRows.Add([object[]]@([string]$item.Name,[string]$item.Category,[string]$item.Kind,$selected,[string]$item.Decision,[string]$item.Status,$spec,[string]$item.Owner,[string]$item.Reason,$why))}
        Add-WsmAssistiveReportTable $lines 'Discovery, selected intent and independent review decision' @('Item','Category','Kind','Selected','Decision','Discovery status','Spec adapter','Owner','Decision reason','Selection reason') $selectionRows.ToArray() 'No inventory items were recorded.'

        $softwareRows=New-Object 'System.Collections.Generic.List[object]'
        foreach($row in @(Get-WsmAssistiveReportInventorySoftware $sourceInventory 'Source')){$softwareRows.Add($row)}
        if($baselineInventory){foreach($row in @(Get-WsmAssistiveReportInventorySoftware $baselineInventory 'Target baseline')){$softwareRows.Add($row)}}
        if($currentInventory){foreach($row in @(Get-WsmAssistiveReportInventorySoftware $currentInventory 'Target current')){$softwareRows.Add($row)}}
        Add-WsmAssistiveReportTable $lines 'Observed software evidence' @('Snapshot','Product','Publisher','Observed version','Architecture','Scope','Account context','Observed location','Capture status') $softwareRows.ToArray() 'No software catalogs were captured in the linked inventory snapshots.'
        if(Get-WsmAssistiveReportComparisonIsCurrent $catalog){
            $comparisonRows=New-Object 'System.Collections.Generic.List[object]';foreach($row in @($catalog.Assistive.Comparison.Rows)){$comparisonRows.Add([object[]]@([string]$row.Name,[string]$row.Publisher,[string]$row.Status,[string]$row.SourceVersion,[string]$row.ChosenVersion,[string]$row.ObservedTargetVersion,[string]$row.BaselineObservedVersion,[string]$row.Reason))}
            Add-WsmAssistiveReportTable $lines 'Current source / chosen / target comparison' @('Product','Publisher','Status','Source version','Chosen version','Observed current version','First observed baseline','Comparison note') $comparisonRows.ToArray() 'The current comparison has no rows. The report does not infer a comparison from version strings.'
            $preparationRows=New-Object 'System.Collections.Generic.List[object]';foreach($work in @($catalog.Assistive.Comparison.ManualPreparation)){$preparationRows.Add([object[]]@([string]$work.Name,[string]$work.SoftwareId,[string]$work.Status,[string]$work.Owner,[string]$work.Action,[string]$work.CompatibilityDisclaimer))}
            Add-WsmAssistiveReportTable $lines 'Manual software and coverage preparation' @('Product or probe','SoftwareId','Status','Owner','Next action','Compatibility limit') $preparationRows.ToArray() 'No manual software preparation is recorded by this current comparison.'
            $lines.Add('<section><h2>Comparison limits</h2><p>'+ (ConvertTo-WsmAssistiveReportText $catalog.Assistive.Comparison.VersionDisclaimer) +'</p><p>Equality or a chosen newer version does not establish compatibility, provider, architecture, account scope, configuration, operation or business readiness.</p></section>')
        }else{$lines.Add('<section><h2>Software comparison</h2><p class="empty">'+(ConvertTo-WsmAssistiveReportText $comparisonState)+'. Collect/import a target inventory and explicitly publish a current comparison before relying on differences.</p></section>')}
        $pathRows=Get-WsmAssistiveReportPathRows $catalog
        Add-WsmAssistiveReportTable $lines 'Original, saved and effective paths' @('Consumer','ItemId','Selected','Decision','Channel / kind','Record','Original / source path','Effective / target path','Relative path or field pointer','Mapping status / hash','Selection / reason') $pathRows 'No file scopes or typed workload path references were recorded.'
        $manualRows=Get-WsmAssistiveReportManualRows $catalog
        Add-WsmAssistiveReportTable $lines 'Selected manual work and unresolved preparation' @('Item','ItemId','Adapter','Discovery status','Decision','Owner','Next action','Reason / procedure') $manualRows 'No selected items are currently identified as manual by the saved catalog; this does not imply execution or business acceptance.'

        $historyRows=New-Object 'System.Collections.Generic.List[object]';foreach($entry in @($catalog.Assistive.RestoreDecisionHistory)){$choice='';if($entry.PSObject.Properties['Choice']){$choice=[string]$entry.Choice}elseif($entry.PSObject.Properties['Decision']){$choice=[string]$entry.Decision};$time='';if($entry.PSObject.Properties['CreatedUtc']){$time=[string]$entry.CreatedUtc}elseif($entry.PSObject.Properties['Utc']){$time=[string]$entry.Utc};$ids='';if($entry.PSObject.Properties['SelectedItemIds']){$ids=@($entry.SelectedItemIds) -join ', '};$historyRows.Add([object[]]@($choice,[string]$entry.Owner,$time,[string]$entry.Generation,[string]$entry.TargetSnapshotHash,[string]$entry.ComparisonRevision,$ids,[string]$entry.Reason,[string]$entry.ExecutionAuthorized))}
        Add-WsmAssistiveReportTable $lines 'Target restore decisions recorded in the manager catalog' @('Decision / choice','Owner','Time','Generation','Target snapshot hash','Comparison revision','Selected ItemIds','Reason','Execution authorized') $historyRows.ToArray() 'No restore-decision history is linked to the manager catalog. External target receipts are not reconstructed here.'
        $resultRows=Get-WsmAssistiveReportResultRows $workspaceFull $catalog
        Add-WsmAssistiveReportTable $lines 'Imported results and environment observations' @('Result kind','Created UTC','Truthful state','Rows / checks','Summary','SHA256') $resultRows 'No result references are imported. Target journals remain the authority for execution and repair.'
        $probeRows=New-Object 'System.Collections.Generic.List[object]';foreach($reference in @($catalog.Assistive.ResultReferences | Where-Object {$_.PSObject.Properties['Kind'] -and $_.Kind -ceq 'AssistiveEnvironmentProbe'})){$probePath=Get-WsmAssistiveReportReferencePath $workspaceFull $reference 'Environment probe';$probe=Read-WsmTrustedJson $probePath ([string]$reference.SHA256);foreach($check in @($probe.Checks)){$probeRows.Add([object[]]@([string]$probe.Role,[string]$probe.CreatedUtc,[string]$check.CheckId,[string]$check.Status,[string]$check.Evidence,[string]$reference.SHA256))}}
        Add-WsmAssistiveReportTable $lines 'Read-only environment probe checks' @('Role','Observed UTC','Check','Status','Observation / next step','SHA256') $probeRows.ToArray() 'No environment probe result is imported. Probe observations never establish business validation or production qualification.'

        $lines.Add('<section><h2>Portable, hash-verified evidence index</h2>')
        if($indexRows.Count -eq 0){$lines.Add('<p class="empty">No protected evidence was copied.</p>')}
        else{$lines.Add('<div class="table-wrap"><table><thead><tr><th scope="col">Evidence</th><th scope="col">Kind</th><th scope="col">Metadata reference</th><th scope="col">Original SHA256</th><th scope="col">Projection SHA256</th></tr></thead><tbody>');foreach($entry in $indexRows){$safePath=[Net.WebUtility]::HtmlEncode([string]$entry.PortablePath);$safeLabel=[Net.WebUtility]::HtmlEncode([string]$entry.Label);$lines.Add('<tr><td>'+$safeLabel+'</td><td>'+(ConvertTo-WsmAssistiveReportText $entry.Kind)+'</td><td><a href="'+$safePath+'">Open evidence reference</a></td><td><code>'+(ConvertTo-WsmAssistiveReportText $entry.OriginalSHA256)+'</code></td><td><code>'+(ConvertTo-WsmAssistiveReportText $entry.ProjectionSHA256)+'</code></td></tr>')};$lines.Add('</tbody></table></div>')}
        $lines.Add('<p class="small">The portable JSON files contain original hashes and document metadata only. Original inventories, configuration contents and payload remain in the protected workspace; these document projections are not restore or import authority.</p></section>')
        $stageProjection=Get-WsmAssistiveReportStageResults $catalog
        $stageRows=New-Object 'System.Collections.Generic.List[object]';foreach($stageResult in @($stageProjection.AllCurrent | Sort-Object @{Expression={if($_.PSObject.Properties['PayloadGeneration']){[long]$_.PayloadGeneration}else{0}};Descending=$true},@{Expression={[DateTimeOffset]::Parse($_.ProducedUtc)};Descending=$true},@{Expression={[long]$_.Sequence};Descending=$true})){$generationText='';$manifestText='';$journalText='';if($stageResult.PSObject.Properties['PayloadGeneration']){$generationText=[string]$stageResult.PayloadGeneration};if($stageResult.PSObject.Properties['ManifestHash']){$manifestText=[string]$stageResult.ManifestHash};if($stageResult.PSObject.Properties['JournalHash']){$journalText=[string]$stageResult.JournalHash};$stageRows.Add([object[]]@([string]$stageResult.Stage,[string]$stageResult.Status,$generationText,$manifestText,[string]$stageResult.ProducedUtc,$journalText,[string]$stageResult.ToolVersion))}
        Add-WsmAssistiveReportTable $lines 'Accepted stage-result history for this approval' @('Stage','Status','Generation','Manifest hash','Produced UTC','Journal hash','Tool version') $stageRows.ToArray() 'No current stage results are imported. Historical result evidence from another catalog revision or approval is not treated as current.'
        $restoreResults=@($stageProjection.AllCurrent | Where-Object {$_.Stage -in @('Restore','FinalDelta')} | Sort-Object @{Expression={[long]$_.PayloadGeneration};Descending=$true},@{Expression={[DateTimeOffset]::Parse($_.ProducedUtc)};Descending=$true});$currentRestore=$null;if($restoreResults.Count){$currentRestore=$restoreResults[0]}
        $transferStatus='NotTested';if($currentRestore){$transferStatus=([string]$currentRestore.Stage+': '+[string]$currentRestore.Status+' (accepted result, generation '+[string]$currentRestore.PayloadGeneration+')')};if(@($catalog.Assistive.ResultReferences | Where-Object {$_.PSObject.Properties['Kind'] -and $_.Kind -ceq 'AssistiveNonCTransferResult'}).Count){$transferStatus+='; D result reference imported, workload completion remains owner-reviewed'}
        $businessStatus='NotTested';$businessResults=@();if($currentRestore){$businessResults=@($stageProjection.AllCurrent | Where-Object {$_.Stage -ceq 'PostCutoverValidation' -and $_.ManifestHash -ieq $currentRestore.ManifestHash -and [long]$_.PayloadGeneration -eq [long]$currentRestore.PayloadGeneration} | Sort-Object @{Expression={[DateTimeOffset]::Parse($_.ProducedUtc)};Descending=$true})};if($businessResults.Count){$businessStatus='PostCutoverValidation: '+[string]$businessResults[0].Status+' (accepted exact manifest/generation '+[string]$businessResults[0].PayloadGeneration+')'}
        $lines.Add('<section><h2>Latest accepted per-item stage result</h2><p class="small">These rows were accepted into the manager catalog after plan, target, generation and item-set validation. The target journal remains the authority for durable writes and repair.</p></section>')
        Add-WsmAssistiveReportTable $lines 'Stage result item vector' @('Item','ItemId','Stage','Item status','Stage status','Generation','Stage manifest','Applied manifest','Applied generation','Pending','Deferred') $stageProjection.Rows 'No current accepted schema 3 per-item stage result is linked to this catalog.'
        $stageFileRows=Get-WsmAssistiveReportFileResultRows $stageProjection $catalog
        Add-WsmAssistiveReportTable $lines 'Complete per-file C / Non-C result and placement evidence' @('Workload','ItemId','Channel','Relative path','Original source path','Preserved target path','Verified effective path','File status','Existing target path','Existing target hash','Source hash','Observed target hash','Reason / uncertainty','EntryId','Row generation','Projected generation') $stageFileRows 'No current per-file C / Non-C result rows are recorded. Empty results do not establish that the approved file set was empty.'
        $countProjection=Get-WsmAssistiveReportCountRows $catalog $stageProjection $stageFileRows
        $total=$countProjection.Totals
        $countTotalRows=@([object[]]@('All discovered objects',$total.Discovered),[object[]]@('Currently selected target subset',$total.Selected),[object[]]@('Currently selected and source-approved Includes',$total.ApprovedSelected),[object[]]@('Explicitly excluded objects',$total.Excluded),[object[]]@('Unsupported discovered objects',$total.Unsupported),[object[]]@('Objects in latest accepted stage result',$total.AcceptedStageObjects),[object[]]@('Selected ManualWorkflow objects still pending',$total.ManualPending),[object[]]@('Accepted pending objects',$total.Pending),[object[]]@('Accepted deferred objects',$total.Deferred),[object[]]@('Accepted file ownership conflicts',$total.OwnershipConflicts),[object[]]@('Availability checks','NotTested'),[object[]]@('File expansion boundary',$total.FileExpansion))
        Add-WsmAssistiveReportTable $lines 'Discovery, selection and execution denominators' @('Measure','Count or evidence state') $countTotalRows 'No count summary is available.'
        Add-WsmAssistiveReportTable $lines 'Per-phase and transfer-channel counts' @('Phase','Channel','Discovered objects','Current selected subset','Selected source Includes','Accepted stage objects','Selected ManualWorkflow objects','Accepted pending','Accepted deferred','Availability','Accepted file rows','Verified placements') $countProjection.Rows 'No channel counts are available.'
        $lines.Add('<section class="small"><p>Object totals use the current imported inventory, current selection and source Include decisions as separate denominators. Stage counts use only the latest accepted result that is current for this catalog. C / Non-C file rows count accepted result entries; they do not estimate undiscovered files or imply that an approved file scope was fully expanded. File expansion and availability remain Unknown / NotTested unless corresponding current evidence exists. No combined completion percentage is calculated.</p></section>')
        $gateRows=@([object[]]@('C-channel package/restore evidence',$transferStatus,'Accepted stage results are bound to the current catalog approval; inspect the target journal for exact readback and repair state.'),[object[]]@('D / Non-C transfer',$(if(@($catalog.Assistive.ResultReferences | Where-Object {$_.PSObject.Properties['Kind'] -and $_.Kind -ceq 'AssistiveNonCTransferResult'}).Count){'Result imported; each required consumer still needs its recorded completion disposition'}else{'NotTested'}),'The separate D result and per-item C restore state do not imply each other.'),[object[]]@('Business validation',$businessStatus,'An accepted current-generation stage result is shown; business owners retain responsibility for application acceptance.'),[object[]]@('Cutover / source retirement','NotTested','No independent cutover acceptance and retirement gate is inferred by this report.'),[object[]]@('Production qualification','NotTested','This report does not qualify the tool or the migration for production.'))
        Add-WsmAssistiveReportTable $lines 'Transfer, business and cutover gate status' @('Gate','Recorded state','Evidence boundary') $gateRows 'Gate state is not recorded.'
        $lines.Add('<section class="foot"><strong>Next-step boundary.</strong> A report is a snapshot for review. Refresh changed source or target evidence, update the comparison, resolve only the affected prerequisites, create a new explicit target decision receipt for the exact approved plan/generation, then inspect target-owned operation state and independent business validation before cutover or retirement. This report does not claim any of those gates passed.</section>')
        $lines.Add('</main></body></html>')
        $indexPath=Join-Path $bundle 'index.html';$temp=$indexPath+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
        try{[IO.File]::WriteAllText($temp,($lines -join "`n"),(New-Object Text.UTF8Encoding($false)));[IO.File]::Move($temp,$indexPath)}finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
        if((Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash -ine $catalogHash){throw 'Catalog changed during report export; the report snapshot is not publishable.'}
        $snapshotHashes=New-Object 'System.Collections.Generic.List[string]';foreach($snapshot in @($catalog.Assistive.SourceSnapshot,$catalog.Assistive.TargetBaseline,$catalog.Assistive.TargetCurrent)){if($snapshot -and $snapshot.SHA256){$snapshotHashes.Add([string]$snapshot.SHA256)}}
        $documentMembers=New-Object 'System.Collections.Generic.List[object]';$originalByPath=@{};foreach($entry in $indexRows){$originalByPath[[string]$entry.PortablePath]=[string]$entry.OriginalSHA256}
        foreach($file in @(Get-ChildItem -LiteralPath $bundle -File -Recurse)){Assert-WsmNoReparse $file.FullName;$relative=$file.FullName.Substring($bundle.TrimEnd('\').Length+1).Replace('\','/');$projectionHash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant();$originalHash='';if($originalByPath.ContainsKey($relative)){$originalHash=$originalByPath[$relative]};$documentMembers.Add([pscustomobject][ordered]@{Path=$relative;Bytes=[long]$file.Length;OriginalSHA256=$originalHash;ProjectionSHA256=$projectionHash})}
        $documentManifestPath=Join-Path $bundle 'document-manifest.json';$documentManifest=[pscustomobject][ordered]@{SchemaVersion=1;Kind='AssistiveReportDocumentManifest';DocumentId=[Guid]::NewGuid().ToString();PairId=[string]$catalog.PairId;CatalogRevision=[int]$catalog.DecisionRevision;AssistiveRevision=[int]$catalog.Assistive.Revision;SelectionRevision=[int]$catalog.Assistive.Selections.Revision;CatalogHash=$catalogHash;SourceSnapshotHash=[string]$catalog.Assistive.SourceSnapshot.SHA256;CreatedUtc=(Get-WsmUtc);Members=$documentMembers.ToArray()};Write-WsmJson $documentManifestPath $documentManifest
        $documentManifestHash=(Get-FileHash -LiteralPath $documentManifestPath -Algorithm SHA256).Hash.ToLowerInvariant();$verified=Test-WsmAssistiveReport -ManifestPath $documentManifestPath -ExpectedHash $documentManifestHash
        [pscustomobject][ordered]@{ReportPath=$indexPath;IndexPath=$indexPath;SHA256=(Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash.ToLowerInvariant();BundlePath=$bundle;BundleName=[IO.Path]::GetFileName($bundle);DocumentManifestPath=$documentManifestPath;DocumentManifestHash=$documentManifestHash;DocumentId=$verified.DocumentId;DocumentMemberCount=$verified.MemberCount;EvidenceDirectory=$evidenceDirectory;CatalogRevision=[int]$catalog.DecisionRevision;AssistiveRevision=[int]$catalog.Assistive.Revision;SelectionRevision=[int]$catalog.Assistive.Selections.Revision;CatalogHash=$catalogHash;SourceSnapshotHash=[string]$catalog.Assistive.SourceSnapshot.SHA256;SnapshotHashes=$snapshotHashes.ToArray();PortableEvidenceCount=$indexRows.Count;ProductionVerified=$false;BusinessValidationStatus=$businessStatus;TransferStatus=$transferStatus;QualificationStatus='NotTested'}
    }catch{
        if([IO.Directory]::Exists($bundle) -and [IO.Path]::GetFullPath($bundle).StartsWith($outputFull.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $bundle -Recurse -Force}
        throw
    }
}
