function Assert-WsmIdentityMap($Map) {
    Assert-WsmFields $Map @('Mappings') @('Mappings');$seen=@{}
    foreach($m in $Map.Mappings){Assert-WsmFields $m @('SourceSid','TargetAccount','ExpectedTargetSid','CreatedByItemId','Owner','Evidence') @('SourceSid','TargetAccount','ExpectedTargetSid','CreatedByItemId','Owner','Evidence');if($m.SourceSid -notmatch '^S-1-\d+(?:-\d+)+$' -or -not $m.TargetAccount -or $m.TargetAccount -match '[\x00-\x1f]' -or -not $m.Owner -or -not $m.Evidence -or $seen.ContainsKey($m.SourceSid)){throw 'Invalid/duplicate identity mapping.'};if($m.ExpectedTargetSid -and $m.ExpectedTargetSid -notmatch '^S-1-\d+(?:-\d+)+$'){throw 'Invalid expected target SID.'};if($m.CreatedByItemId -and $m.CreatedByItemId -notmatch '^[a-f0-9]{64}$'){throw 'Invalid identity dependency item.'};$seen[$m.SourceSid]=$true}
}
function Set-WsmIdentityMap {
    param([string]$Workspace,[string]$PairId,[string]$Path,[string]$ExpectedHash,[int]$ExpectedRevision)
    $map=Read-WsmTrustedJson $Path $ExpectedHash;Assert-WsmIdentityMap $map
    Invoke-WsmLocked $Workspace {$c=Get-WsmCatalog $Workspace $PairId;if($c.DecisionRevision -ne $ExpectedRevision){throw 'Review changed.'};foreach($m in $map.Mappings){if($m.CreatedByItemId){$item=@($c.Items | Where-Object ItemId -CEQ $m.CreatedByItemId);if($item.Count -ne 1 -or -not $item[0].PSObject.Properties['MigrationSpec'] -or $item[0].MigrationSpec.Adapter -notin @('LocalUser','LocalGroup')){throw 'SID map dependency must be a reviewed local user/group item.'}}};$c | Add-Member NoteProperty IdentityMap $map -Force;$c.DecisionRevision++;$c.Approval=$null;$c.History=@($c.History)+@([pscustomobject]@{Action='IdentityMap';Revision=$c.DecisionRevision;Utc=(Get-WsmUtc)});Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c}
}
function Resolve-WsmAccountSid([string]$Account) {
    $name=New-Object Security.Principal.NTAccount($Account);$name.Translate([Security.Principal.SecurityIdentifier]).Value
}
function Test-WsmSddlMatch([string]$Expected,[string]$Actual,[string]$Policy='Exact') {
    if($Policy -eq 'Exact'){return ($Expected -ceq $Actual)}
    if($Policy -cne 'AllowAutoInheritedUpgrade'){throw 'Unknown reviewed ACL control policy.'}
    $before=New-Object Security.AccessControl.RawSecurityDescriptor($Expected);$after=New-Object Security.AccessControl.RawSecurityDescriptor($Actual)
    $auto=[Security.AccessControl.ControlFlags]::DiscretionaryAclAutoInherited -bor [Security.AccessControl.ControlFlags]::SystemAclAutoInherited
    if(([int]$before.ControlFlags -band [int]$auto -band (-bnot [int]$after.ControlFlags)) -ne 0){return $false}
    # This is an explicitly reviewed one-way OS inheritance conversion, not byte-exact ACL restoration.
    # Owner/group, all ACEs (including inherited ACE flags), P/AR and every other SDDL bit remain exact.
    $before.SetFlags([Security.AccessControl.ControlFlags]([int]$before.ControlFlags -band (-bnot [int]$auto)))
    $after.SetFlags([Security.AccessControl.ControlFlags]([int]$after.ControlFlags -band (-bnot [int]$auto)))
    $before.GetSddlForm('All') -ceq $after.GetSddlForm('All')
}
function Resolve-WsmIdentityMap($Plan,[hashtable]$Provided=@{},[switch]$AllowPlannedMissing) {
    $map=@{};if($Plan.PSObject.Properties['IdentityMap']){Assert-WsmIdentityMap $Plan.IdentityMap;foreach($m in $Plan.IdentityMap.Mappings){try{$sid=Resolve-WsmAccountSid $m.TargetAccount}catch{if($AllowPlannedMissing -and $m.CreatedByItemId){continue};throw ('Target account cannot be resolved: '+$m.TargetAccount)};if($m.ExpectedTargetSid -and $sid -cne $m.ExpectedTargetSid){throw 'Target account SID drift; review required.'};$map[$m.SourceSid]=$sid}}
    foreach($key in $Provided.Keys){if(-not $map.ContainsKey($key) -or $map[$key] -cne $Provided[$key]){throw 'Runtime SID override is not in the approved target account map.'}}
    $map
}
function Assert-WsmResolvableSddl([string]$Sddl) {
    $d=New-Object Security.AccessControl.RawSecurityDescriptor($Sddl);$sids=@($d.Owner,$d.Group);if($d.DiscretionaryAcl){foreach($ace in $d.DiscretionaryAcl){if($ace -is [Security.AccessControl.KnownAce]){$sids+=@($ace.SecurityIdentifier)}}};if($d.SystemAcl){foreach($ace in $d.SystemAcl){if($ace -is [Security.AccessControl.KnownAce]){$sids+=@($ace.SecurityIdentifier)}}}
    foreach($sid in $sids){if(-not $sid){continue};try{[void]$sid.Translate([Security.Principal.NTAccount])}catch{throw ('Unresolved SID in mapped ACL: '+$sid.Value+'; approve an account mapping or dedicated ACL procedure.') }}
}
