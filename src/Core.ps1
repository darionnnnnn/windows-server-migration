function Get-WsmUtc { [DateTime]::UtcNow.ToString('o') }
function Get-WsmHashText([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Read-WsmJson([string]$Path) {
    $file = Get-Item -LiteralPath $Path
    if ($file.Length -gt 128MB) { throw 'Input exceeds the 128 MiB JSON limit.' }
    [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
}
function Write-WsmJson([string]$Path, $Data) {
    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not [IO.Directory]::Exists($directory)) { [void][IO.Directory]::CreateDirectory($directory) }
    $temporary = Join-Path $directory ([Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json=$Data | ConvertTo-Json -Depth 40
        if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 128MB) { throw 'Output exceeds 128 MiB; split the host review scope before continuing.' }
        [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
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
    if (-not [Guid]::TryParseExact($Id, 'D', [ref]$parsed)) { throw 'Invalid identity: expected a GUID.' }
}
function Assert-WsmEnvelope($Data, [string]$Kind) {
    foreach ($field in @('SchemaVersion','ToolVersion','Kind')) {
        if (-not $Data.PSObject.Properties[$field]) { throw ('Missing envelope field: ' + $field) }
    }
    if (($Data.SchemaVersion -isnot [int] -and $Data.SchemaVersion -isnot [long]) -or $Data.SchemaVersion -ne 1 -or $Data.Kind -cne $Kind) { throw 'Unsupported schema or envelope kind.' }
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
    Assert-WsmInventory $result
    $result
}
function Import-WsmInventory {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Workspace, [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedHash, [string]$TargetName)
    Assert-WsmTrustedFile $Path $ExpectedHash
    $inventory = Read-WsmJson $Path
    Assert-WsmInventory $inventory
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
            if ($previous.ContainsKey($entry.ItemId)) {
                $prior=$previous[$entry.ItemId]
                if ($prior.SettingsHash -ceq $entry.SettingsHash -and $prior.Present -and $prior.Status -ceq $entry.Status -and $prior.Adapter -ceq $entry.Adapter -and (($prior.Dependencies | ConvertTo-Json -Compress -Depth 10) -ceq ($entry.Dependencies | ConvertTo-Json -Compress -Depth 10))) {
                    foreach ($field in @('Decision','Reason','ReviewedBy','ReviewedUtc','RuleId','Mapping','Evidence','Owner')) { if ($prior.PSObject.Properties[$field]) { $item.$field = $prior.$field } }
                } else { $item.Reason='Changed since previous inventory; review required.' }
                $previous.Remove($entry.ItemId)
            }
            $items.Add($item)
        }
        foreach ($prior in $previous.Values) { $prior.Present=$false; $prior.Decision='Pending'; $prior.Reason='No longer observed; investigate before approval.'; $items.Add($prior) }
        $decisionRevision=0
        if ($old) { $decisionRevision=$old.DecisionRevision+1 }
        $history=@(); if ($old) { $history=@($old.History)+@([pscustomobject]@{ Revision=$decisionRevision; Action='Inventory'; Utc=(Get-WsmUtc) }) }
        $pair.SourceName=$inventory.Source.Name
        $catalog = [pscustomobject][ordered]@{ SchemaVersion=1; ToolVersion=$script:ToolVersion; Kind='Catalog'; BatchId=$fleet.BatchId; PairId=$pair.PairId; Source=$inventory.Source; TargetName=$pair.TargetName; InventoryRevision=$inventory.Revision; DecisionRevision=$decisionRevision; InventoryHash=$ExpectedHash.ToLowerInvariant(); ImportedUtc=(Get-WsmUtc); Approval=$null; Items=@($items.ToArray()); History=$history }
        Write-WsmJson (Get-WsmCatalogPath $Workspace $pair.PairId) $catalog
        Write-WsmJson (Join-Path $Workspace 'fleet.json') $fleet
        $catalog
    }
}
