function Get-WsmUtc { [DateTime]::UtcNow.ToString('o') }
function New-WsmContractError([string]$Message) { New-Object IO.InvalidDataException($Message) }
$script:WsmJsonDateKindSupported=(Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')
function ConvertFrom-WsmJson([string]$Text) {
    if ($script:WsmJsonDateKindSupported) { ConvertFrom-Json -InputObject $Text -DateKind String }
    else { ConvertFrom-Json -InputObject $Text }
}
function Get-WsmHashText([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Read-WsmJson([string]$Path) {
    $file = Get-Item -LiteralPath $Path
    if ($file.Length -gt 128MB) { throw 'Input exceeds the 128 MiB JSON limit.' }
    ConvertFrom-WsmJson ([IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8))
}
function Write-WsmJson([string]$Path, $Data) {
    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not [IO.Directory]::Exists($directory)) { [void][IO.Directory]::CreateDirectory($directory) }
    $temporary = Join-Path $directory ([Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json=$Data | ConvertTo-Json -Depth 40
        if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 128MB) { throw 'Output exceeds 128 MiB; no scope splitting is implemented. Preserve the existing workspace and request large-inventory support.' }
        $stream=[IO.File]::Open($temporary,'CreateNew','Write','None');try{$bytes=[Text.Encoding]::UTF8.GetBytes($json);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        if ([IO.File]::Exists($Path)) {
            $backup=Join-Path $directory ([Guid]::NewGuid().ToString('N')+'.bak')
            [IO.File]::Replace($temporary, $Path, $backup)
            [IO.File]::Delete($backup)
        }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function Assert-WsmId([string]$Id) {
    $parsed = [Guid]::Empty
    if (-not [Guid]::TryParseExact($Id, 'D', [ref]$parsed)) { throw (New-WsmContractError 'Invalid identity: expected a GUID.') }
}
function Assert-WsmEnvelope($Data, [string]$Kind) {
    foreach ($field in @('SchemaVersion','ToolVersion','Kind')) {
        if (-not $Data.PSObject.Properties[$field]) { throw (New-WsmContractError ('Missing envelope field: ' + $field)) }
    }
    if (($Data.SchemaVersion -isnot [int] -and $Data.SchemaVersion -isnot [long]) -or $Data.Kind -cne $Kind) { throw (New-WsmContractError 'Unsupported schema or envelope kind.') }
    if ($Data.SchemaVersion -eq 1) {
        if (($Kind -eq 'Catalog' -and $Data.PSObject.Properties['GeneralHost']) -or ($Kind -eq 'MigrationPlan' -and $Data.PSObject.Properties['ScopeMode'] -and $Data.ScopeMode -ceq 'GeneralHost')) { throw (New-WsmContractError 'GeneralHost data requires schema 2; legacy readers must reject it.') }
    } elseif ($Data.SchemaVersion -eq 2) {
        if ($Kind -eq 'Catalog') { if (-not $Data.PSObject.Properties['GeneralHost'] -or -not (Get-Command Assert-WsmGeneralHostContract -ErrorAction SilentlyContinue)) { throw (New-WsmContractError 'Schema 2 Catalog requires the GeneralHost contract validator.') }; Assert-WsmGeneralHostContract $Data | Out-Null }
        elseif ($Kind -eq 'MigrationPlan') { if (-not $Data.PSObject.Properties['ScopeMode'] -or $Data.ScopeMode -cne 'GeneralHost' -or -not $Data.PSObject.Properties['GeneralHost']) { throw (New-WsmContractError 'Schema 2 MigrationPlan requires GeneralHost scope and contract.') }; if (-not (Get-Command Assert-WsmGeneralHostContract -ErrorAction SilentlyContinue)) { throw (New-WsmContractError 'GeneralHost contract validator is unavailable.') }; Assert-WsmGeneralHostContract $Data | Out-Null }
        else { throw (New-WsmContractError 'Schema 2 is unsupported for this envelope kind.') }
    } elseif ($Data.SchemaVersion -eq 3) {
        if (@('Catalog','MigrationPlan') -cnotcontains $Kind -or $Data.ToolVersion -cne '0.4.0') { throw (New-WsmContractError 'Schema 3 requires tool version 0.4.0 and a Catalog or MigrationPlan envelope.') }
        if (-not (Get-Command Assert-WsmAssistiveContract -ErrorAction SilentlyContinue)) { throw (New-WsmContractError 'Assistive contract validator is unavailable; legacy readers must reject schema 3.') }
        Assert-WsmAssistiveContract $Data $Kind | Out-Null
        if ($Kind -eq 'Catalog' -and $Data.PSObject.Properties['GeneralHost']) { Assert-WsmGeneralHostContract $Data | Out-Null }
        if ($Kind -eq 'MigrationPlan' -and $Data.PSObject.Properties['GeneralHost']) { Assert-WsmGeneralHostContract $Data | Out-Null }
    } else { throw (New-WsmContractError 'Unsupported schema version.') }
    if (@('0.1.0','0.2.0','0.3.0','0.4.0') -cnotcontains $Data.ToolVersion) { throw (New-WsmContractError 'Unsupported tool version; do not reinterpret future data.') }
}
function Assert-WsmInventory($Inventory) {
    Assert-WsmEnvelope $Inventory 'Inventory'
    Assert-WsmId $Inventory.Source.HostId
    if (($Inventory.Revision -isnot [int] -and $Inventory.Revision -isnot [long]) -or $Inventory.Revision -lt 1 -or $Inventory.Revision -gt [int]::MaxValue) { throw 'Invalid inventory revision.' }
    if ($Inventory.Source.Fingerprint -notmatch '^[a-f0-9]{64}$') { throw 'Invalid source fingerprint.' }
    $ids = @{}
    foreach ($item in @($Inventory.Items)) {
        foreach ($field in @('ItemId','Category','Kind','Name','NaturalKey','Settings','SettingsHash','Dependencies','Status','Adapter')) {
            if (-not $item.PSObject.Properties[$field]) { throw ('Missing item field: ' + $field) }
        }
        if ($script:Categories -cnotcontains $item.Category -or $item.ItemId -notmatch '^[a-f0-9]{64}$') { throw 'Invalid item category or ID.' }
        if ($ids.ContainsKey($item.ItemId)) { throw 'Duplicate inventory ItemId.' }
        $ids[$item.ItemId] = $true
        $expected = Get-WsmHashText ($Inventory.Source.HostId + '|' + $item.Category + '|' + $item.Kind + '|' + $item.NaturalKey.ToLowerInvariant())
        if ($expected -cne $item.ItemId) { throw 'Item identity does not match its source/natural key.' }
        if ($item.SettingsHash -cne (Get-WsmHashText ($item.Settings | ConvertTo-Json -Depth 30 -Compress))) { throw 'Invalid item settings hash.' }
        if ($item.PSObject.Properties['Classification']) { Assert-WsmScopeClassification -Item $item | Out-Null }
        if (@('Success','Partial','NotInstalled','PermissionDenied','Unsupported','Failed') -cnotcontains $item.Status) { throw 'Unknown collector status.' }
        foreach ($dependency in @($item.Dependencies)) {
            if ($dependency.ItemId -notmatch '^[a-f0-9]{64}$' -or @('Mandatory','Optional','External') -cnotcontains $dependency.Type) { throw 'Invalid dependency.' }
        }
    }
}
function Assert-WsmTrustedFile([string]$Path, [string]$ExpectedHash) {
    if ($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$') { throw 'An independently obtained SHA256 is required.' }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $ExpectedHash) { throw 'Trusted SHA256 mismatch; input not imported.' }
}
function Read-WsmFileSnapshot([string]$Path,[string]$ExpectedHash) {
    $stream=[IO.File]::Open([IO.Path]::GetFullPath($Path),'Open','Read','Read')
    try {
        if ($stream.Length -gt 128MB) { throw 'Input exceeds 128 MiB.' }
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $hash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
        if ($ExpectedHash -and ($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$' -or $hash -ine $ExpectedHash)) { throw (New-WsmContractError 'Trusted SHA256 mismatch; input not imported.') }
        $stream.Position=0; $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
        try { $text=$reader.ReadToEnd() } finally { $reader.Dispose() }
        [pscustomobject]@{ Text=$text; Hash=$hash }
    } finally { $stream.Dispose() }
}
function Read-WsmTrustedJson([string]$Path,[string]$ExpectedHash) {
    if ($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$') { throw 'An independently obtained SHA256 is required.' }
    ConvertFrom-WsmJson (Read-WsmFileSnapshot $Path $ExpectedHash).Text
}
function Protect-WsmDirectory([string]$Path) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner($identity.User)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($identity.User.Value, 'S-1-5-18', 'S-1-5-32-544') | Select-Object -Unique) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Invoke-WsmLocked([string]$Workspace, [scriptblock]$Action) {
    if(Get-Command Assert-WsmOutputWorkspaceNotMigrated -ErrorAction SilentlyContinue){Assert-WsmOutputWorkspaceNotMigrated $Workspace}
    $lock = $null
    try {
        $lock = [IO.File]::Open((Join-Path $Workspace '.wsm.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        & $Action
    } finally { if ($lock) { $lock.Dispose() } }
}
function Initialize-WsmWorkspace {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Workspace)
    $Workspace = [IO.Path]::GetFullPath($Workspace)
    $path = Join-Path $Workspace 'fleet.json'
    if (Test-Path -LiteralPath $path) { return Get-WsmFleet $Workspace }
    if (-not (Test-Path -LiteralPath $Workspace)) { [void][IO.Directory]::CreateDirectory($Workspace); Protect-WsmDirectory $Workspace }
    Invoke-WsmLocked $Workspace {
        if (Test-Path -LiteralPath $path) { throw 'Workspace initialized by another process.' }
        $fleet = [pscustomobject][ordered]@{ SchemaVersion=1; ToolVersion=$script:ToolVersion; Kind='Fleet'; BatchId=[Guid]::NewGuid().ToString(); CreatedUtc=(Get-WsmUtc); Pairs=@() }
        Write-WsmJson $path $fleet
        $fleet
    }
}
function Get-WsmFleet {
    param([Parameter(Mandatory)][string]$Workspace)
    if([IO.File]::Exists((Join-Path $Workspace 'workspace-transaction.json'))){throw 'Interrupted workspace transaction; run RepairWorkspace before reading or editing.'}
    $fleet = Read-WsmJson (Join-Path $Workspace 'fleet.json')
    Assert-WsmEnvelope $fleet 'Fleet'
    Assert-WsmId $fleet.BatchId
    $fleet
}
function Get-WsmCatalogPath([string]$Workspace, [string]$PairId) {
    Assert-WsmId $PairId
    Join-Path (Join-Path $Workspace 'pairs') ($PairId + '.json')
}
function Get-WsmCatalog {
    param([Parameter(Mandatory)][string]$Workspace, [Parameter(Mandatory)][string]$PairId)
    $catalog = Read-WsmJson (Get-WsmCatalogPath $Workspace $PairId)
    Assert-WsmEnvelope $catalog 'Catalog'
    if ($catalog.PairId -cne $PairId -or $catalog.BatchId -cne (Get-WsmFleet $Workspace).BatchId) { throw 'Catalog identity mismatch.' }
    if ($catalog.PSObject.Properties['SoftwareCatalog']) { if (-not (Get-Command Get-WsmCatalogInventoryProjection -ErrorAction SilentlyContinue)) { throw 'Catalog software source projection validator is unavailable.' }; Assert-WsmSoftwareCatalog $catalog.SoftwareCatalog -SourceInventory (Get-WsmCatalogInventoryProjection $catalog) | Out-Null }
    if ($catalog.SchemaVersion -eq 2) { Assert-WsmGeneralHostContract $catalog | Out-Null }
    if ($catalog.SchemaVersion -eq 3) { Assert-WsmAssistiveWorkspaceReferences $Workspace $catalog | Out-Null; if($catalog.PSObject.Properties['GeneralHost']){Assert-WsmGeneralHostContract $catalog | Out-Null} }
    if ($catalog.ToolVersion -eq '0.1.0') { foreach ($item in $catalog.Items) { [void](Get-WsmReviewDefaults $item) }; $catalog.ToolVersion=$script:ToolVersion; $catalog.Approval=$null }
    foreach ($item in @($catalog.Items)) { if ($item.PSObject.Properties['Classification']) { Assert-WsmScopeClassification -Item $item | Out-Null } }
    $catalog
}
function New-WsmItem {
    param([Parameter(Mandatory)][string]$HostId, [Parameter(Mandatory)][string]$Category, [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$NaturalKey, $Settings=@{}, [object[]]$Dependencies=@(),
        [ValidateSet('Success','Partial','NotInstalled','PermissionDenied','Unsupported','Failed')][string]$Status='Success', [string]$Adapter='Manual')
    Assert-WsmId $HostId
    if ($script:Categories -cnotcontains $Category) { throw 'Unknown category.' }
    [pscustomobject][ordered]@{ ItemId=(Get-WsmHashText ($HostId+'|'+$Category+'|'+$Kind+'|'+$NaturalKey.ToLowerInvariant())); Category=$Category; Kind=$Kind; Name=$Name; NaturalKey=$NaturalKey; Settings=$Settings; SettingsHash=(Get-WsmHashText ($Settings | ConvertTo-Json -Depth 30 -Compress)); Dependencies=@($Dependencies); Status=$Status; Adapter=$Adapter }
}
function New-WsmInventory {
    param([Parameter(Mandatory)]$Source, [Parameter(Mandatory)][int]$Revision, [object[]]$Items=@())
    $result = [pscustomobject][ordered]@{ SchemaVersion=1; ToolVersion=$script:ToolVersion; Kind='Inventory'; Source=$Source; Revision=$Revision; CreatedUtc=(Get-WsmUtc); Items=@($Items) }
    $summary=@(foreach ($category in $script:Categories) { $rows=@($Items | Where-Object Category -CEQ $category); [pscustomobject]@{ Category=$category; Total=$rows.Count; Success=@($rows | Where-Object Status -EQ Success).Count; Incomplete=@($rows | Where-Object Status -NE Success).Count } })
    $result | Add-Member NoteProperty CategorySummary $summary
    Assert-WsmInventory $result
    $result
}
function Import-WsmInventory {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Workspace, [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedHash, [string]$TargetName)
    $inventory = Read-WsmTrustedJson $Path $ExpectedHash
    Assert-WsmInventory $inventory
    if ($inventory.PSObject.Properties['SoftwareCatalog']) { Assert-WsmSoftwareCatalog $inventory.SoftwareCatalog -SourceInventory $inventory | Out-Null }
    $sourceSnapshot=Read-WsmFileSnapshot $Path $ExpectedHash
    Invoke-WsmLocked $Workspace {
        $fleet = Get-WsmFleet $Workspace
        $existing = @($fleet.Pairs | Where-Object { $_.SourceHostId -ceq $inventory.Source.HostId })
        $sameFingerprint = @($fleet.Pairs | Where-Object { $_.SourceFingerprint -ceq $inventory.Source.Fingerprint -and $_.SourceHostId -cne $inventory.Source.HostId })
        if ($sameFingerprint.Count) { throw 'Source fingerprint is already enrolled under another identity; inspect clone/re-enrollment.' }
        if ($existing.Count -gt 1) { throw 'Duplicate pair registration.' }
        $old = $null
        if ($existing.Count) {
            $pair = $existing[0]
            if ($pair.SourceFingerprint -cne $inventory.Source.Fingerprint) { throw 'Source identity fingerprint changed.' }
            $old = Get-WsmCatalog $Workspace $pair.PairId
            if ($inventory.Revision -le $old.InventoryRevision) { throw 'Inventory revision is stale or already imported.' }
        } else {
            if (-not $TargetName) { throw 'TargetName is required for a new pair.' }
            if (@($fleet.Pairs | Where-Object { $_.TargetName -ieq $TargetName }).Count) { throw 'Target is already assigned to another source.' }
            $pair = [pscustomobject]@{ PairId=[Guid]::NewGuid().ToString(); SourceHostId=$inventory.Source.HostId; SourceFingerprint=$inventory.Source.Fingerprint; SourceName=$inventory.Source.Name; TargetName=$TargetName }
            $fleet.Pairs = @($fleet.Pairs) + @($pair)
        }
        $previous = @{}
        if ($old) { foreach ($item in $old.Items) { $previous[$item.ItemId]=$item } }
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($entry in $inventory.Items) {
            $item = [pscustomobject][ordered]@{ ItemId=$entry.ItemId; Category=$entry.Category; Kind=$entry.Kind; Name=$entry.Name; NaturalKey=$entry.NaturalKey; Settings=$entry.Settings; SettingsHash=$entry.SettingsHash; Dependencies=@($entry.Dependencies); Status=$entry.Status; Adapter=$entry.Adapter; Decision='Pending'; Reason=''; ReviewedBy=''; ReviewedUtc=''; RuleId=''; Mapping=''; Evidence=''; Owner=''; Present=$true }
            [void](Get-WsmReviewDefaults $item)
            if ($entry.PSObject.Properties['BuiltIn']) { $item.BuiltIn=$entry.BuiltIn }
            if ($entry.PSObject.Properties['Classification']) { $item | Add-Member NoteProperty Classification $entry.Classification }
            if ($previous.ContainsKey($entry.ItemId)) {
                $prior=$previous[$entry.ItemId]
                if ($prior.SettingsHash -ceq $entry.SettingsHash -and $prior.Present -and $prior.Status -ceq $entry.Status -and $prior.Adapter -ceq $entry.Adapter -and (($prior.Dependencies | ConvertTo-Json -Compress -Depth 10) -ceq ($entry.Dependencies | ConvertTo-Json -Compress -Depth 10))) {
                    [void](Get-WsmReviewDefaults $item)
                    foreach ($field in @('Decision','Reason','ReviewedBy','ReviewedUtc','RuleId','Mapping','Evidence','Owner','AccountMapping','EndpointMapping','ApplicationGroup','BuiltIn','ConsistencyGroup','ConsistencyOwner','ConsistencyEvidence','MigrationSpec','GeneralHostOverride')) { if ($prior.PSObject.Properties[$field]) { $item | Add-Member NoteProperty $field $prior.$field -Force } }
                } else { $item.Reason='Changed since previous inventory; review required.' }
                $previous.Remove($entry.ItemId)
            }
            $items.Add($item)
        }
        foreach ($prior in $previous.Values) { if (-not $prior.ManualEntry) { $prior.Present=$false; $prior.Decision='Pending'; $prior.Reason='No longer observed; investigate before approval.' }; $items.Add($prior) }
        $decisionRevision=0
        if ($old) { $decisionRevision=$old.DecisionRevision+1 }
        $history=@(); if ($old) { $history=@($old.History)+@([pscustomobject]@{ Revision=$decisionRevision; Action='Inventory'; Utc=(Get-WsmUtc) }) }
        $pair.SourceName=$inventory.Source.Name
        $snapshotDirectory=Join-Path (Join-Path $Workspace 'assistive') 'snapshots'
        if(-not [IO.Directory]::Exists($snapshotDirectory)){[void][IO.Directory]::CreateDirectory($snapshotDirectory);Protect-WsmDirectory $snapshotDirectory}
        $snapshotPath=Join-Path $snapshotDirectory ($ExpectedHash.ToLowerInvariant()+'.json')
        Assert-WsmNoReparse $snapshotPath
        if([IO.File]::Exists($snapshotPath)){if((Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash -ine $ExpectedHash){throw 'Content-addressed inventory snapshot hash collision.'}}
        else{$temporary=$snapshotPath+'.'+[Guid]::NewGuid().ToString('N')+'.tmp';try{[IO.File]::WriteAllBytes($temporary,[IO.File]::ReadAllBytes([IO.Path]::GetFullPath($Path)));if((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ine $ExpectedHash){throw 'Trusted inventory snapshot bytes changed before durable write.'};[IO.File]::Move($temporary,$snapshotPath)}finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}}
        $catalog = [pscustomobject][ordered]@{ SchemaVersion=1; ToolVersion=$script:ToolVersion; Kind='Catalog'; BatchId=$fleet.BatchId; PairId=$pair.PairId; Source=$inventory.Source; TargetName=$pair.TargetName; InventoryRevision=$inventory.Revision; DecisionRevision=$decisionRevision; InventoryHash=$ExpectedHash.ToLowerInvariant(); ImportedUtc=(Get-WsmUtc); Approval=$null; Items=@($items.ToArray()); History=$history }
        if ($inventory.PSObject.Properties['SoftwareCatalog']) { $catalog | Add-Member NoteProperty SoftwareCatalog $inventory.SoftwareCatalog }
        if ($inventory.PSObject.Properties['WorkloadDiscovery']) { $catalog | Add-Member NoteProperty WorkloadDiscovery $inventory.WorkloadDiscovery }
        elseif ($old -and $old.PSObject.Properties['WorkloadDiscovery']) { $catalog | Add-Member NoteProperty WorkloadDiscovery $old.WorkloadDiscovery }
        if ($old -and $old.PSObject.Properties['ReviewView']) { $catalog | Add-Member NoteProperty ReviewView $old.ReviewView }
        foreach ($field in @('PairPlan','CrossHostDependencies','StageResults','IdentityMap')) { if ($old -and $old.PSObject.Properties[$field]) { $catalog | Add-Member NoteProperty $field $old.$field } }
        if ($old -and $old.PSObject.Properties['Assistive']) {
            $catalog | Add-Member NoteProperty Assistive (New-WsmAssistiveCatalogContract $pair.PairId ('assistive/snapshots/'+$ExpectedHash.ToLowerInvariant()+'.json') $ExpectedHash.ToLowerInvariant() ([int]$inventory.Revision) @($items.ToArray()) $old.Assistive)
            $catalog.SchemaVersion=3;$catalog.ToolVersion='0.4.0'
        }
        if ($old -and $old.PSObject.Properties['GeneralHost']) {
            if(-not $catalog.PSObject.Properties['Assistive']){$catalog.SchemaVersion=2};$priorSoftwareDecisions=@($old.GeneralHost.SoftwareDecisions);$general=$old.GeneralHost;$validIds=@{};foreach($item in @($items.ToArray())){$validIds[$item.ItemId]=$true}
            $orphaned=New-Object System.Collections.Generic.List[object]
            foreach($requirement in @($general.Requirements)){$orphaned.Add($requirement)}
            $general.Requirements=@();$general.OrphanedRequirements=@($general.OrphanedRequirements)+@($orphaned.ToArray());$general.SoftwareCatalog=$null;$general.SoftwareCatalogHash='';$general.SoftwareDecisions=@();if($inventory.PSObject.Properties['SoftwareCatalog']){$general.SoftwareCatalog=$inventory.SoftwareCatalog;$general.SoftwareCatalogHash=Get-WsmHashText ($inventory.SoftwareCatalog | ConvertTo-Json -Depth 30 -Compress);$general.SoftwareDecisions=@($priorSoftwareDecisions | Where-Object {$decision=$_;$entry=@($inventory.SoftwareCatalog.Entries | Where-Object SoftwareId -CEQ $decision.SoftwareId);$entry.Count -eq 1 -and $decision.SoftwareHash -ceq (Get-WsmGeneralHostSoftwareFactsHash $entry[0])})};$general.EvidenceReceipts=@();$general.UpdatedUtc=Get-WsmUtc;$catalog | Add-Member NoteProperty GeneralHost $general
        }
        if($catalog.SchemaVersion -eq 3){Assert-WsmAssistiveContract $catalog Catalog | Out-Null}
        $catalog | Add-Member NoteProperty EvidenceUtc $inventory.CreatedUtc
        Write-WsmWorkspaceTransaction $Workspace $catalog $fleet
        $catalog
    }
}
