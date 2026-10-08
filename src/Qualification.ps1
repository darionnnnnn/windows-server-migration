function ConvertTo-WsmQualificationUtc([string]$Value,[string]$Field) {
    $parsed=[DateTimeOffset]::MinValue
    if(-not [DateTimeOffset]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -or $parsed.Offset -ne [TimeSpan]::Zero){throw (New-WsmContractError ($Field+' must be an ISO-8601 UTC timestamp.'))}
    $parsed
}
function Assert-WsmQualificationText([string]$Value,[string]$Field,[int]$Maximum=512) {
    if([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt $Maximum -or $Value -match '[\x00-\x08\x0b\x0c\x0e-\x1f]'){throw (New-WsmContractError ('Invalid qualification '+$Field+'.'))}
}
function Get-WsmQualificationKey($Tuple) {
    Assert-WsmFields $Tuple @('ToolFingerprint','Adapter','AdapterFingerprint','Source','Target','Product','ProductVersion') @('ToolFingerprint','Adapter','AdapterFingerprint','Source','Target','Product','ProductVersion')
    foreach($name in @('ToolFingerprint','AdapterFingerprint')){if([string]$Tuple.$name -notmatch '^[a-fA-F0-9]{64}$'){throw (New-WsmContractError ('Invalid '+$name+'.'))}}
    Assert-WsmQualificationText ([string]$Tuple.Adapter) Adapter 128;Assert-WsmQualificationText ([string]$Tuple.Product) Product 256;Assert-WsmQualificationText ([string]$Tuple.ProductVersion) ProductVersion 128
    foreach($side in @('Source','Target')){Assert-WsmFields $Tuple.$side @('Family','Version','Build','Edition','Architecture') @('Family','Version','Build','Edition','Architecture');foreach($field in @('Family','Version','Build','Edition','Architecture')){Assert-WsmQualificationText ([string]$Tuple.$side.$field) ($side+'.'+$field) 128}}
    $canonical=[ordered]@{ToolFingerprint=$Tuple.ToolFingerprint.ToLowerInvariant();Adapter=[string]$Tuple.Adapter;AdapterFingerprint=$Tuple.AdapterFingerprint.ToLowerInvariant();Source=[ordered]@{Family=[string]$Tuple.Source.Family;Version=[string]$Tuple.Source.Version;Build=[string]$Tuple.Source.Build;Edition=[string]$Tuple.Source.Edition;Architecture=[string]$Tuple.Source.Architecture};Target=[ordered]@{Family=[string]$Tuple.Target.Family;Version=[string]$Tuple.Target.Version;Build=[string]$Tuple.Target.Build;Edition=[string]$Tuple.Target.Edition;Architecture=[string]$Tuple.Target.Architecture};Product=[string]$Tuple.Product;ProductVersion=[string]$Tuple.ProductVersion}
    Get-WsmHashText (($canonical | ConvertTo-Json -Depth 8 -Compress))
}
function Get-WsmQualificationRecordKey {
    [CmdletBinding()]param([Parameter(Mandatory)][ValidateNotNull()]$Tuple)
    Get-WsmQualificationKey $Tuple
}
function New-WsmQualificationRecord {
    [CmdletBinding()]param([Parameter(Mandatory)][ValidateNotNull()]$Tuple,[Parameter(Mandatory)][ValidateSet('PilotOnly','ProductionAccepted')][string]$ReleaseDecision,[Parameter(Mandatory)][ValidateNotNull()]$Requirements,[Parameter(Mandatory)][ValidateNotNull()][object[]]$Evidence,[Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CreatedBy)
    $record=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='QualificationRecord';QualificationId=[Guid]::NewGuid().ToString();Key=(Get-WsmQualificationKey $Tuple);Tuple=$Tuple;ReleaseDecision=$ReleaseDecision;Requirements=$Requirements;Evidence=$Evidence;CreatedUtc=(Get-WsmUtc);CreatedBy=$CreatedBy}
    [void](Assert-WsmQualificationRecord $record);$record
}
function Assert-WsmQualificationRecord($Record) {
    Assert-WsmEnvelope $Record QualificationRecord
    Assert-WsmFields $Record @('SchemaVersion','ToolVersion','Kind','QualificationId','Key','Tuple','ReleaseDecision','Requirements','Evidence','CreatedUtc','CreatedBy') @('QualificationId','Key','Tuple','ReleaseDecision','Requirements','Evidence','CreatedUtc','CreatedBy')
    Assert-WsmId $Record.QualificationId
    $key=Get-WsmQualificationKey $Record.Tuple;if($key -cne $Record.Key){throw (New-WsmContractError 'Qualification key does not match its exact tuple.')}
    if($Record.ReleaseDecision -cnotin @('PilotOnly','ProductionAccepted')){throw (New-WsmContractError 'Invalid qualification release decision.')}
    Assert-WsmQualificationText ([string]$Record.CreatedBy) CreatedBy 256;$created=ConvertTo-WsmQualificationUtc ([string]$Record.CreatedUtc) CreatedUtc;if($created -gt [DateTimeOffset]::UtcNow.AddMinutes(5)){throw 'Qualification creation is in the future.'}
    Assert-WsmFields $Record.Requirements @('Permissions','ConsistencyMethod','RebootBehavior','SideEffects','RollbackLevel') @('Permissions','ConsistencyMethod','RebootBehavior','SideEffects','RollbackLevel')
    foreach($field in @('Permissions','ConsistencyMethod','RebootBehavior','SideEffects','RollbackLevel')){Assert-WsmQualificationText ([string]$Record.Requirements.$field) ('Requirements.'+$field) 2048}
    if(@($Record.Evidence).Count -lt 1 -or @($Record.Evidence).Count -gt 50){throw (New-WsmContractError 'Qualification requires 1–50 evidence records.')}
    $ids=@{};foreach($e in $Record.Evidence){Assert-WsmFields $e @('EvidenceId','Type','Owner','Reference','ObservedUtc','ExpiresUtc','SHA256') @('EvidenceId','Type','Owner','Reference','ObservedUtc','ExpiresUtc','SHA256');Assert-WsmId $e.EvidenceId;if($ids.ContainsKey($e.EvidenceId)){throw (New-WsmContractError 'Duplicate qualification evidence ID.')};$ids[$e.EvidenceId]=$true
        if($e.Type -cnotin @('Fixture','RealFiles','ServerLab','IsolatedPilot','ProductionAcceptance')){throw (New-WsmContractError 'Unknown qualification evidence type.')};foreach($field in @('Owner','Reference')){Assert-WsmQualificationText ([string]$e.$field) ('Evidence.'+$field) 1024};if([string]$e.SHA256 -notmatch '^[a-fA-F0-9]{64}$'){throw (New-WsmContractError 'Evidence requires a SHA256 reference digest.')};$observed=ConvertTo-WsmQualificationUtc ([string]$e.ObservedUtc) ObservedUtc;$expires=ConvertTo-WsmQualificationUtc ([string]$e.ExpiresUtc) ExpiresUtc;if($expires -le $observed -or $expires -le $created){throw (New-WsmContractError 'Evidence expiry must follow observation and qualification creation time.')}
    }
    if($Record.ReleaseDecision -eq 'ProductionAccepted'){$needed=@('ServerLab','IsolatedPilot','ProductionAcceptance');$types=@($Record.Evidence | ForEach-Object Type);foreach($type in $needed){if($types -cnotcontains $type){throw (New-WsmContractError ('Production acceptance requires '+$type+' evidence.'))}}}
    $Record
}
function Get-WsmQualificationRegistry([string]$Path) {
    if(-not [IO.File]::Exists($Path)){return [pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='QualificationRegistry';Records=@();Revocations=@()}}
    $r=Read-WsmJson $Path;Assert-WsmEnvelope $r QualificationRegistry;Assert-WsmFields $r @('SchemaVersion','ToolVersion','Kind','Records','Revocations') @('Records','Revocations')
    if(@($r.Records).Count -gt 10000 -or @($r.Revocations).Count -gt 10000){throw (New-WsmContractError 'Qualification registry entry limit exceeded.')}
    $seen=@{};foreach($record in $r.Records){[void](Assert-WsmQualificationRecord $record);if($seen.ContainsKey($record.QualificationId)){throw (New-WsmContractError 'Duplicate qualification ID.')};$seen[$record.QualificationId]=$true}
    $revoked=@{};foreach($v in $r.Revocations){Assert-WsmFields $v @('QualificationId','Owner','Reference','Utc') @('QualificationId','Owner','Reference','Utc');Assert-WsmId $v.QualificationId;Assert-WsmQualificationText ([string]$v.Owner) RevocationOwner 256;Assert-WsmQualificationText ([string]$v.Reference) RevocationReference 1024;[void](ConvertTo-WsmQualificationUtc ([string]$v.Utc) RevocationUtc);if(-not $seen.ContainsKey($v.QualificationId)){throw (New-WsmContractError 'Revocation references unknown qualification.')};$revoked[$v.QualificationId]=$true}
    [pscustomobject]@{SchemaVersion=1;ToolVersion=$r.ToolVersion;Kind='QualificationRegistry';Records=@($r.Records);Revocations=@($r.Revocations)}
}
function Add-WsmQualification {
    [CmdletBinding()]param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,[Parameter(Mandatory)][ValidateNotNull()]$Record)
    [void](Assert-WsmQualificationRecord $Record);$directory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path));if(-not [IO.Directory]::Exists($directory)){[void][IO.Directory]::CreateDirectory($directory)}
    Invoke-WsmLocked $directory {$registry=Get-WsmQualificationRegistry $Path;if(@($registry.Records | Where-Object QualificationId -CEQ $Record.QualificationId).Count){throw 'Qualification ID already exists.'};$prior=@($registry.Records | Where-Object Key -CEQ $Record.Key | Sort-Object @{Expression={ConvertTo-WsmQualificationUtc ([string]$_.CreatedUtc) CreatedUtc}} -Descending | Select-Object -First 1);if($prior.Count -and (ConvertTo-WsmQualificationUtc ([string]$Record.CreatedUtc) CreatedUtc) -le (ConvertTo-WsmQualificationUtc ([string]$prior[0].CreatedUtc) CreatedUtc)){throw 'Qualification revisions for an exact tuple must have increasing creation times.'};$registry.Records=@($registry.Records)+@($Record);Write-WsmJson $Path $registry;[pscustomobject]@{Path=[IO.Path]::GetFullPath($Path);QualificationId=$Record.QualificationId;Key=$Record.Key;ReleaseDecision=$Record.ReleaseDecision}}
}
function Revoke-WsmQualification {
    [CmdletBinding()]param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,[Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$QualificationId,[Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Owner,[Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Reference)
    Assert-WsmId $QualificationId;Assert-WsmQualificationText $Owner Owner 256;Assert-WsmQualificationText $Reference Reference 1024;$directory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    Invoke-WsmLocked $directory {$registry=Get-WsmQualificationRegistry $Path;if(-not @($registry.Records | Where-Object QualificationId -CEQ $QualificationId).Count){throw 'Unknown qualification ID.'};if(@($registry.Revocations | Where-Object QualificationId -CEQ $QualificationId).Count){throw 'Qualification is already revoked.'};$registry.Revocations=@($registry.Revocations)+@([pscustomobject]@{QualificationId=$QualificationId;Owner=$Owner;Reference=$Reference;Utc=(Get-WsmUtc)});Write-WsmJson $Path $registry;[pscustomobject]@{QualificationId=$QualificationId;Revoked=$true}}
}
function Get-WsmQualification {
    [CmdletBinding()]param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,[Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$Key)
    $registry=Get-WsmQualificationRegistry $Path;$matches=@($registry.Records | Where-Object Key -CEQ $Key | Sort-Object @{Expression={ConvertTo-WsmQualificationUtc ([string]$_.CreatedUtc) CreatedUtc}} -Descending);if(-not $matches.Count){return $null};$record=$matches[0];$revoked=@($registry.Revocations | Where-Object QualificationId -CEQ $record.QualificationId).Count -gt 0
    [pscustomobject]@{Record=$record;Revoked=$revoked}
}
function Resolve-WsmProductionQualification {
    [CmdletBinding()]param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,[Parameter(Mandatory)][ValidateNotNull()]$Tuple)
    $key=Get-WsmQualificationKey $Tuple;$found=Get-WsmQualification $Path $key;$problems=New-Object 'System.Collections.Generic.List[string]'
    if(-not $found){$problems.Add('No exact tool/adapter/source/target/product qualification exists.');return [pscustomobject]@{Qualified=$false;Key=$key;Record=$null;Problems=$problems.ToArray()}}
    $r=$found.Record;if($found.Revoked){$problems.Add('Qualification was revoked.')};if($r.ReleaseDecision -ne 'ProductionAccepted'){$problems.Add('Release decision is not ProductionAccepted.')}
    $now=[DateTimeOffset]::UtcNow;foreach($e in $r.Evidence){if((ConvertTo-WsmQualificationUtc ([string]$e.ExpiresUtc) ExpiresUtc) -le $now){$problems.Add(('Evidence expired: '+$e.Type))};if((ConvertTo-WsmQualificationUtc ([string]$e.ObservedUtc) ObservedUtc) -gt $now.AddMinutes(5)){$problems.Add(('Evidence observation is in the future: '+$e.Type))}}
    foreach($type in @('ServerLab','IsolatedPilot','ProductionAcceptance')){if(@($r.Evidence | Where-Object {$_.Type -ceq $type -and (ConvertTo-WsmQualificationUtc ([string]$_.ExpiresUtc) ExpiresUtc) -gt $now}).Count -eq 0){$problems.Add(('Current '+$type+' evidence missing.'))}}
    [pscustomobject]@{Qualified=($problems.Count -eq 0);Key=$key;Record=$r;Problems=$problems.ToArray()}
}
function Get-WsmQualificationMatrix {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RegistryPath,[Parameter(Mandatory)][string]$TuplesPath,[Parameter(Mandatory)][string]$TuplesHash,[string]$OutputPath)
    $input=Read-WsmTrustedJson $TuplesPath $TuplesHash;Assert-WsmFields $input @('Tuples') @('Tuples');if(@($input.Tuples).Count -gt 10000){throw 'Qualification matrix exceeds 10000 reviewed tuples.'}
    $tool=Get-WsmToolFingerprint;$matrix=@{};foreach($capability in (Get-WsmAdapterMatrix)){$matrix[$capability.Adapter]=$capability}
    $rows=@(foreach($tuple in $input.Tuples){[void](Get-WsmQualificationKey $tuple);if(-not $matrix.ContainsKey($tuple.Adapter)){throw 'Unknown adapter in qualification tuple.'};$resolved=Resolve-WsmProductionQualification $RegistryPath $tuple;$current=($tuple.ToolFingerprint -ieq $tool);[pscustomobject]@{Tuple=$tuple;InstalledToolMatches=$current;QualificationRecorded=($resolved.Qualified -and $current);EvidenceAssertion='Owner-reviewed references and hashes; actual host qualification must be independently audited';ExecutionMode='IsolatedPilot';ProductionExecutionEnabled=$false;Problems=@($resolved.Problems)+@($(if(-not $current){'Installed tool fingerprint differs.'}));Capability=$matrix[$tuple.Adapter];Requirements=$(if($resolved.Record){$resolved.Record.Requirements}else{$null})}})
    $result=[pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='QualificationMatrix';ProducedUtc=(Get-WsmUtc);ToolFingerprint=$tool;Rows=$rows;ProductionExecutionEnabled=$false}
    if($OutputPath){Write-WsmJson $OutputPath $result};$result
}
