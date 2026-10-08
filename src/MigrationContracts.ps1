function Get-WsmMachineIdentity {
    if ([string]$ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { throw 'Migration requires FullLanguage under the approved enterprise deployment policy.' }
    $pre=Get-WsmPreflight
    $machine=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
    $uuid=(Get-CimInstance Win32_ComputerSystemProduct).UUID
    [pscustomobject]@{ Fingerprint=(Get-WsmHashText ($machine+'|'+$uuid)); Name=$env:COMPUTERNAME; OS=$pre.OS; Version=$pre.Version; IsServer=$pre.IsServer; Administrator=$pre.Administrator; Is64Bit=$pre.Is64Bit }
}
function Assert-WsmMigrationHost($Identity,[string]$Fingerprint) {
    if (-not $Identity.IsServer -or -not $Identity.Administrator -or -not $Identity.Is64Bit -or $Identity.Fingerprint -cne $Fingerprint) { throw (New-WsmContractError 'Migration host identity/platform/privilege mismatch.') }
    if ([string]$ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { throw 'Migration requires FullLanguage; policy is not changed.' }
}
function Register-WsmTarget {
    param([string]$StateDirectory,[string]$Path)
    $identity=Get-WsmMachineIdentity
    Assert-WsmMigrationHost $identity $identity.Fingerprint
    if (-not [IO.Directory]::Exists($StateDirectory)) { [void][IO.Directory]::CreateDirectory($StateDirectory); Protect-WsmDirectory $StateDirectory }
    Invoke-WsmLocked $StateDirectory {
        $statePath=Join-Path $StateDirectory 'target-identity.json'
        if ([IO.File]::Exists($statePath)) { $target=Read-WsmJson $statePath; Assert-WsmEnvelope $target 'TargetIdentity'; if ($target.Fingerprint -cne $identity.Fingerprint) { throw 'Target state belongs to a different machine.' } }
        else { $target=[pscustomobject]@{ SchemaVersion=1; ToolVersion=$script:ToolVersion; Kind='TargetIdentity'; HostId=[Guid]::NewGuid().ToString(); Fingerprint=$identity.Fingerprint; Name=$identity.Name; OS=$identity.OS; Version=$identity.Version; CreatedUtc=(Get-WsmUtc) }; Write-WsmJson $statePath $target }
        Write-WsmJson $Path $target
        [pscustomobject]@{ Path=[IO.Path]::GetFullPath($Path); SHA256=(Get-FileHash -LiteralPath $Path).Hash; Target=$target }
    }
}
function Assert-WsmFields($Object,[string[]]$Allowed,[string[]]$Required=@()) {
    foreach ($p in $Object.PSObject.Properties.Name) { if ($Allowed -cnotcontains $p) { throw (New-WsmContractError ('Unknown contract field: '+$p)) } }
    foreach ($p in $Required) { if (-not $Object.PSObject.Properties[$p]) { throw (New-WsmContractError ('Missing contract field: '+$p)) } }
}
function Assert-WsmWorkspaceSeparation($Plan,[string]$Workspace,[ValidateSet('SourcePath','TargetPath')][string]$ScopeField) {
    $workspacePath=[IO.Path]::GetFullPath($Workspace).TrimEnd('\');Assert-WsmNoReparse $workspacePath
    $physicalWorkspace=Get-WsmPhysicalPath $workspacePath;$destinations=New-Object 'System.Collections.Generic.List[string]'
    foreach($i in $Plan.Items){if($i.Decision -eq 'Include' -and $i.MigrationSpec.Adapter -eq 'FileScope'){$root=[IO.Path]::GetFullPath($i.MigrationSpec.$ScopeField).TrimEnd('\');$physicalRoot=Get-WsmPhysicalPath $root;if((Test-WsmPathOverlap $workspacePath $root) -or (Test-WsmPathOverlap $physicalWorkspace $physicalRoot)){throw ($ScopeField+' overlaps operation evidence/state workspace; move the tool workspace outside business data before any operation.')};if($ScopeField -eq 'TargetPath'){foreach($prior in $destinations){if(Test-WsmPathOverlap $prior $physicalRoot){throw 'Target scopes overlap through physical aliases.'}};$destinations.Add($physicalRoot)}}}
}
function Assert-WsmSourceWorkspaceSeparation($Plan,[string]$Workspace) {
    Assert-WsmWorkspaceSeparation $Plan $Workspace SourcePath
}
function Assert-WsmRelativePath([string]$Path,[switch]$AllowRoot) {
    if ($AllowRoot -and $Path -eq '') { return }
    if ([string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::IsPathRooted($Path) -or $Path -match '[/:\x00-\x1f<>"|?*]' -or $Path.EndsWith('\') -or $Path -match '\\\\' -or $Path -match '(?:^|\\)(?:\.|\.\.)(?:\\|$)' -or $Path -match '(?i)(?:^|\\)(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|\\|$)' -or $Path -match '[. ](?:\\|$)') { throw (New-WsmContractError 'Unsafe relative artifact path.') }
}
function Assert-WsmNoReparse([string]$Path) {
    $cursor=[IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if ([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor)) { if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw ('Reparse point requires dedicated approved handling: '+$cursor) } }
        $parent=[IO.Path]::GetDirectoryName($cursor.TrimEnd('\')); if ($parent -eq $cursor) { break }; $cursor=$parent
    }
}
function Get-WsmAdapterMatrix {
    foreach ($name in @('FileScope','ScheduledTask','Service','SmbShare','MachineEnvironment','WindowsFeature','IISPool','IISSite','Certificate','LocalUser','LocalGroup','FirewallRule','ManualWorkflow')) {
        [pscustomobject]@{ Adapter=$name; Version=1; ExportImplemented=$true; RestoreImplemented=$true; VerifyImplemented=$true; ProductionVerified=$false; RequiredMode='IsolatedPilot'; Rollback='SnapshotOrRemoveCreated'; Secrets='InMemoryCredentialOrIndependentArtifact'; SupportedSource='Windows Server with required API'; SupportedTarget='Windows Server with required API' }
    }
}
function Assert-WsmMigrationSpec($Spec) {
    $allowed=@('Adapter','Desired','SourcePath','TargetPath','ExcludedRelativePaths','Consistency','Metadata','ConflictPolicy','SecretRef','Owner','Evidence','DesiredFinalState','BusinessChecks','Product','Procedure','Artifacts','RequiredCommands','AclControlPolicy','CatchUpPolicy')
    Assert-WsmFields $Spec $allowed @('Adapter','Owner','Evidence')
    if($Spec.PSObject.Properties['AclControlPolicy'] -and ($Spec.Adapter -ne 'FileScope' -or $Spec.AclControlPolicy -cnotin @('Exact','AllowAutoInheritedUpgrade'))){throw 'ACL control policy must be explicitly reviewed for FileScope.'}
    if($Spec.PSObject.Properties['CatchUpPolicy'] -and $Spec.Adapter -ne 'ScheduledTask'){throw 'CatchUpPolicy is only valid for ScheduledTask.'}
    if (@((Get-WsmAdapterMatrix).Adapter) -cnotcontains $Spec.Adapter -or [string]::IsNullOrWhiteSpace($Spec.Owner) -or [string]::IsNullOrWhiteSpace($Spec.Evidence)) { throw (New-WsmContractError 'Unknown adapter or missing owner/evidence.') }
    if ($Spec.Adapter -eq 'FileScope') {
        foreach ($f in @('SourcePath','TargetPath','ExcludedRelativePaths','Consistency','Metadata','ConflictPolicy')) { if (-not $Spec.PSObject.Properties[$f]) { throw ('FileScope requires '+$f) } }
        [void](ConvertTo-WsmCanonicalPath $Spec.SourcePath); [void](ConvertTo-WsmCanonicalPath $Spec.TargetPath)
        if (@('Immutable','OwnerFreeze','ProductBackup') -cnotcontains $Spec.Consistency -or @('DaclOwner','DaclOwnerSacl') -cnotcontains $Spec.Metadata -or @('Block','ReplaceOwned') -cnotcontains $Spec.ConflictPolicy) { throw 'Invalid file scope policy.' }
        foreach ($p in $Spec.ExcludedRelativePaths) { Assert-WsmRelativePath $p }
    }
    elseif ($Spec.Adapter -eq 'ManualWorkflow') {
        foreach ($f in @('Product','Procedure','Artifacts','BusinessChecks')) { if (-not $Spec.PSObject.Properties[$f]) { throw ('Dedicated workflow requires '+$f) } }
        if ([string]::IsNullOrWhiteSpace($Spec.Product) -or [string]::IsNullOrWhiteSpace($Spec.Procedure)) { throw 'Dedicated workflow product/procedure required.' }
    }
    elseif (-not $Spec.PSObject.Properties['Desired']) { throw 'Adapter requires explicit reviewed Desired configuration.' }
    if ($Spec.PSObject.Properties['DesiredFinalState'] -and @('Disabled','Enabled','Manual','Automatic','Stopped','Running') -cnotcontains $Spec.DesiredFinalState) { throw 'Invalid final activation state.' }
    if ($Spec.PSObject.Properties['SecretRef'] -and $Spec.SecretRef -notmatch '^[A-Za-z0-9_.-]{1,128}$') { throw 'SecretRef is a reference, never a password.' }
    # Adapter-specific desired field validation is shared with preview and restore.
    if ($Spec.Adapter -ne 'FileScope' -and $Spec.Adapter -ne 'ManualWorkflow') { Assert-WsmAdapterDesired $Spec }
}
function Set-WsmMigrationSpec {
    param([string]$Workspace,[string]$PairId,[string]$ItemId,[string]$Path,[string]$ExpectedHash,[int]$ExpectedRevision)
    $spec=Read-WsmTrustedJson $Path $ExpectedHash; Assert-WsmMigrationSpec $spec
    Invoke-WsmLocked $Workspace {
        $c=Get-WsmCatalog $Workspace $PairId; if ($c.DecisionRevision -ne $ExpectedRevision) { throw 'Review changed.' }
        $rows=@($c.Items | Where-Object ItemId -CEQ $ItemId); if ($rows.Count -ne 1) { throw 'Unknown ItemId.' }
        $rows[0] | Add-Member NoteProperty MigrationSpec $spec -Force
        $rows[0].Owner=$spec.Owner;$rows[0].Evidence=$spec.Evidence
        $c.DecisionRevision++; $c.Approval=$null
        $c.History=@($c.History)+@([pscustomobject]@{ Action='MigrationSpec'; ItemId=$ItemId; Revision=$c.DecisionRevision; Utc=(Get-WsmUtc) })
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c
    }
}
function Approve-WsmMigrationPlan {
    param([string]$Workspace,[string]$PairId,[string]$TargetIdentityPath,[string]$TargetIdentityHash,[string]$Path,[int]$ExpectedRevision,[Parameter(Mandatory)][string]$PilotAcknowledgement)
    if ($PilotAcknowledgement -cne 'ISOLATED-PILOT') { throw 'Adapters require explicit ISOLATED-PILOT acknowledgement until real-server qualification.' }
    $target=Read-WsmTrustedJson $TargetIdentityPath $TargetIdentityHash; Assert-WsmEnvelope $target 'TargetIdentity'; Assert-WsmId $target.HostId
    if ($target.Fingerprint -notmatch '^[a-f0-9]{64}$') { throw 'Invalid target fingerprint.' }
    Invoke-WsmLocked $Workspace {
        $c=Get-WsmCatalog $Workspace $PairId; if ($c.DecisionRevision -ne $ExpectedRevision) { throw 'Review changed.' }
        if (@(Get-WsmReviewIssues $Workspace $PairId | Where-Object Gate -EQ ReviewComplete).Count) { throw 'Complete review and dependencies before migration approval.' }
        if ($target.Fingerprint -ceq $c.Source.Fingerprint) { throw 'Source and target must be different machines.' }
        $included=@($c.Items | Where-Object Decision -EQ Include); if (-not $included.Count) { throw 'No selected migration items.' }
        $destinations=@{}
        foreach ($i in $included) {
            if (-not $i.PSObject.Properties['MigrationSpec']) { throw ('No migration specification for '+$i.ItemId) }; Assert-WsmMigrationSpec $i.MigrationSpec
            if ($i.Status -ne 'Success' -and $i.MigrationSpec.Adapter -ne 'ManualWorkflow' -and $i.MigrationSpec.Adapter -ne 'FileScope') { throw ('Incomplete configuration: '+$i.ItemId) }
            if ($i.MigrationSpec.Adapter -eq 'FileScope') { $dest=(ConvertTo-WsmCanonicalPath $i.MigrationSpec.TargetPath).TrimEnd('\'); foreach ($prior in $destinations.Keys) { if ($dest -ieq $prior -or $dest.StartsWith($prior+'\',[StringComparison]::OrdinalIgnoreCase) -or $prior.StartsWith($dest+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Migration scopes have overlapping destinations.' } }; $destinations[$dest]=$i.ItemId }
        }
        $plan=[pscustomobject][ordered]@{ SchemaVersion=1; ToolVersion=$script:ToolVersion; Kind='MigrationPlan'; BatchId=$c.BatchId; PairId=$c.PairId; ApprovalId=[Guid]::NewGuid().ToString(); Source=$c.Source; Target=$target; InventoryRevision=$c.InventoryRevision; DecisionRevision=$c.DecisionRevision; InventoryHash=$c.InventoryHash; Mode='IsolatedPilot'; ToolFingerprint=(Get-WsmToolFingerprint); ApprovedUtc=(Get-WsmUtc); Items=@($c.Items | Select-Object ItemId,Category,Kind,Name,NaturalKey,SettingsHash,Dependencies,Decision,Reason,Mapping,AccountMapping,EndpointMapping,Owner,Evidence,MigrationSpec,ConsistencyGroup,ConsistencyOwner,ConsistencyEvidence) }
        if ($c.PSObject.Properties['PairPlan']) { $plan | Add-Member NoteProperty PairPlan $c.PairPlan }
        if($c.PSObject.Properties['IdentityMap']){Assert-WsmIdentityMap $c.IdentityMap;foreach($m in $c.IdentityMap.Mappings){if($m.CreatedByItemId){$creator=@($included | Where-Object ItemId -CEQ $m.CreatedByItemId);if($creator.Count -ne 1 -or $creator[0].MigrationSpec.Desired.Name -ine $m.TargetAccount.Split('\')[-1]){throw 'Identity map must reference the included creator of the reviewed target account.'};foreach($scope in ($plan.Items | Where-Object {$_.Decision -eq 'Include' -and $_.MigrationSpec.Adapter -eq 'FileScope'})){if(-not @($scope.Dependencies | Where-Object ItemId -CEQ $m.CreatedByItemId).Count){$scope.Dependencies=@($scope.Dependencies)+@([pscustomobject]@{ItemId=$m.CreatedByItemId;Type='Mandatory';Evidence='Approved SID mapping prerequisite'})}}}};$plan | Add-Member NoteProperty IdentityMap $c.IdentityMap}
        if ($c.PSObject.Properties['CrossHostDependencies']) { $plan | Add-Member NoteProperty CrossHostDependencies $c.CrossHostDependencies }
        Write-WsmJson $Path $plan
        $hash=(Get-FileHash -LiteralPath $Path).Hash
        $c.Approval=[pscustomobject]@{ ApprovalId=$plan.ApprovalId; Hash=$hash; Utc=$plan.ApprovedUtc; Kind='MigrationPlan'; Mode='IsolatedPilot'; TargetHostId=$target.HostId; TargetFingerprint=$target.Fingerprint }; Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c
        [pscustomobject]@{ Path=[IO.Path]::GetFullPath($Path); SHA256=$hash; Mode='IsolatedPilot'; ProductionVerified=$false }
    }
}
function Read-WsmMigrationPlan([string]$Path,[string]$ExpectedHash) {
    $p=Read-WsmTrustedJson $Path $ExpectedHash; Assert-WsmEnvelope $p 'MigrationPlan'; if(-not $p.PSObject.Properties['ToolFingerprint'] -or $p.ToolFingerprint -cne (Get-WsmToolFingerprint)){throw 'Installed tool bytes changed; reapprove the deployed release before migration.'}
    foreach ($id in @($p.BatchId,$p.PairId,$p.ApprovalId,$p.Source.HostId,$p.Target.HostId)) { Assert-WsmId $id }
    if ($p.Mode -cne 'IsolatedPilot' -or $p.Source.Fingerprint -notmatch '^[a-f0-9]{64}$' -or $p.Target.Fingerprint -notmatch '^[a-f0-9]{64}$') { throw 'Invalid migration mode/identity.' }
    $seen=@{}; foreach ($i in $p.Items) { if ($i.ItemId -notmatch '^[a-f0-9]{64}$' -or $seen.ContainsKey($i.ItemId) -or @('Include','Exclude') -cnotcontains $i.Decision) { throw 'Invalid migration item.' }; $seen[$i.ItemId]=$true; if ($i.Decision -eq 'Include') { Assert-WsmMigrationSpec $i.MigrationSpec } }
    $p
}
