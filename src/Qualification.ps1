function ConvertTo-WsmQualificationUtc([string]$Value,[string]$Field) {
    $parsed=[DateTimeOffset]::MinValue
    if(-not [DateTimeOffset]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -or $parsed.Offset -ne [TimeSpan]::Zero){throw (New-WsmContractError ($Field+' must be an ISO-8601 UTC timestamp.'))}
    $parsed
}
function Assert-WsmQualificationText([string]$Value,[string]$Field,[int]$Maximum=512) {
    if([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt $Maximum -or $Value -match '[\x00-\x08\x0b\x0c\x0e-\x1f]'){throw (New-WsmContractError ('Invalid qualification '+$Field+'.'))}
}
function Get-WsmQualificationRuntime {
    [CmdletBinding()]param()
    $release='Unknown';try{$release=[string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction Stop).Release}catch{}
    $edition='Desktop';if($PSVersionTable.ContainsKey('PSEdition')){$edition=[string]$PSVersionTable.PSEdition}
    $architecture='Unknown';$runtimeType='System.Runtime.InteropServices.RuntimeInformation' -as [type]
    if($runtimeType){$architecture=([string]$runtimeType.GetProperty('ProcessArchitecture').GetValue($null,$null)).ToLowerInvariant()}
    elseif(-not [Environment]::Is64BitProcess){$architecture='x86'}
    elseif($env:PROCESSOR_ARCHITECTURE -ceq 'AMD64'){$architecture='x64'}
    elseif($env:PROCESSOR_ARCHITECTURE -ceq 'ARM64'){$architecture='arm64'}
    [pscustomobject][ordered]@{PowerShellVersion=$PSVersionTable.PSVersion.ToString();Edition=$edition;ProcessArchitecture=$architecture;LanguageMode=[string]$ExecutionContext.SessionState.LanguageMode;CLRVersion=[Environment]::Version.ToString();DotNetFrameworkRelease=$release}
}
function Get-WsmQualificationRuntimeProjection($Runtime) {
    Assert-WsmFields $Runtime @('Source','Target') @('Source','Target');$canonical=[ordered]@{}
    $fields=@('PowerShellVersion','Edition','ProcessArchitecture','LanguageMode','CLRVersion','DotNetFrameworkRelease')
    foreach($side in @('Source','Target')){Assert-WsmFields $Runtime.$side $fields $fields;$row=[ordered]@{};foreach($field in $fields){Assert-WsmQualificationText ([string]$Runtime.$side.$field) ($side+'.Runtime.'+$field) 128;$row[$field]=[string]$Runtime.$side.$field};$canonical[$side]=$row}
    $canonical
}
function Assert-WsmProductionRuntime($Runtime) {
    $projection=Get-WsmQualificationRuntimeProjection $Runtime
    foreach($side in @('Source','Target')){$r=$projection[$side];if($r.PowerShellVersion -notmatch '^5\.1\.\d+\.\d+$' -or $r.Edition -cne 'Desktop' -or $r.ProcessArchitecture -cne 'x64' -or $r.LanguageMode -cne 'FullLanguage' -or $r.CLRVersion -notmatch '^4\.0\.\d+\.\d+$' -or $r.DotNetFrameworkRelease -notmatch '^\d{6,8}$'){throw 'Production runtime must bind exact Windows PowerShell 5.1 x64 FullLanguage and installed .NET Framework servicing metadata.'}}
}
function Get-WsmQualificationKey($Tuple) {
    Assert-WsmFields $Tuple @('ToolFingerprint','Adapter','AdapterFingerprint','Source','Target','Product','ProductVersion','OracleProvider','OracleConsumer','ReleaseArtifact','Runtime') @('ToolFingerprint','Adapter','AdapterFingerprint','Source','Target','Product','ProductVersion')
    foreach($name in @('ToolFingerprint','AdapterFingerprint')){if([string]$Tuple.$name -notmatch '^[a-fA-F0-9]{64}$'){throw (New-WsmContractError ('Invalid '+$name+'.'))}}
    Assert-WsmQualificationText ([string]$Tuple.Adapter) Adapter 128;Assert-WsmQualificationText ([string]$Tuple.Product) Product 256;Assert-WsmQualificationText ([string]$Tuple.ProductVersion) ProductVersion 128
    foreach($side in @('Source','Target')){Assert-WsmFields $Tuple.$side @('Family','Version','Build','Edition','Architecture','InstallationType') @('Family','Version','Build','Edition','Architecture');foreach($field in @('Family','Version','Build','Edition','Architecture')){Assert-WsmQualificationText ([string]$Tuple.$side.$field) ($side+'.'+$field) 128};if($Tuple.$side.PSObject.Properties['InstallationType']){Assert-WsmQualificationText ([string]$Tuple.$side.InstallationType) ($side+'.InstallationType') 128}}
    if($Tuple.PSObject.Properties['OracleProvider'] -or $Tuple.PSObject.Properties['OracleConsumer'] -or $Tuple.Adapter -match 'Oracle' -or $Tuple.Product -match '(?i)Oracle|ODAC|ODP\.NET'){if(-not $Tuple.PSObject.Properties['OracleProvider'] -or -not $Tuple.PSObject.Properties['OracleConsumer']){throw (New-WsmContractError 'Oracle qualification requires both exact provider and consumer dimensions.')};foreach($field in @('Product','Version','Architecture','Context')){Assert-WsmQualificationText ([string]$Tuple.OracleProvider.$field) ('OracleProvider.'+$field) 256;Assert-WsmQualificationText ([string]$Tuple.OracleConsumer.$field) ('OracleConsumer.'+$field) 256}}
    if($Tuple.PSObject.Properties['ReleaseArtifact']){Assert-WsmFields $Tuple.ReleaseArtifact @('ArchiveSHA256','SignatureSHA256','ToolFingerprint','SignerThumbprint','TrustPolicyHash') @('ArchiveSHA256','SignatureSHA256','ToolFingerprint','SignerThumbprint','TrustPolicyHash');foreach($field in @('ArchiveSHA256','SignatureSHA256','ToolFingerprint','TrustPolicyHash')){if([string]$Tuple.ReleaseArtifact.$field -notmatch '^[a-fA-F0-9]{64}$'){throw ('Invalid ReleaseArtifact '+$field+'.')}};Assert-WsmQualificationText ([string]$Tuple.ReleaseArtifact.SignerThumbprint) ReleaseSignerThumbprint 128;if([string]$Tuple.ReleaseArtifact.ToolFingerprint -ine [string]$Tuple.ToolFingerprint){throw 'Release artifact tool fingerprint differs from qualification tuple.'}}
    $canonical=[ordered]@{ToolFingerprint=$Tuple.ToolFingerprint.ToLowerInvariant();Adapter=[string]$Tuple.Adapter;AdapterFingerprint=$Tuple.AdapterFingerprint.ToLowerInvariant();Source=[ordered]@{Family=[string]$Tuple.Source.Family;Version=[string]$Tuple.Source.Version;Build=[string]$Tuple.Source.Build;Edition=[string]$Tuple.Source.Edition;Architecture=[string]$Tuple.Source.Architecture};Target=[ordered]@{Family=[string]$Tuple.Target.Family;Version=[string]$Tuple.Target.Version;Build=[string]$Tuple.Target.Build;Edition=[string]$Tuple.Target.Edition;Architecture=[string]$Tuple.Target.Architecture};Product=[string]$Tuple.Product;ProductVersion=[string]$Tuple.ProductVersion}
    foreach($side in @('Source','Target')){if($Tuple.$side.PSObject.Properties['InstallationType']){$canonical[$side]['InstallationType']=[string]$Tuple.$side.InstallationType}}
    if($Tuple.PSObject.Properties['OracleProvider']){$canonical['OracleProvider']=[ordered]@{Product=[string]$Tuple.OracleProvider.Product;Version=[string]$Tuple.OracleProvider.Version;Architecture=[string]$Tuple.OracleProvider.Architecture;Context=[string]$Tuple.OracleProvider.Context};$canonical['OracleConsumer']=[ordered]@{Product=[string]$Tuple.OracleConsumer.Product;Version=[string]$Tuple.OracleConsumer.Version;Architecture=[string]$Tuple.OracleConsumer.Architecture;Context=[string]$Tuple.OracleConsumer.Context}}
    if($Tuple.PSObject.Properties['ReleaseArtifact']){$canonical['ReleaseArtifact']=[ordered]@{ArchiveSHA256=[string]$Tuple.ReleaseArtifact.ArchiveSHA256.ToLowerInvariant();SignatureSHA256=[string]$Tuple.ReleaseArtifact.SignatureSHA256.ToLowerInvariant();ToolFingerprint=[string]$Tuple.ReleaseArtifact.ToolFingerprint.ToLowerInvariant();SignerThumbprint=[string]$Tuple.ReleaseArtifact.SignerThumbprint.ToUpperInvariant();TrustPolicyHash=[string]$Tuple.ReleaseArtifact.TrustPolicyHash.ToLowerInvariant()}}
    if($Tuple.PSObject.Properties['Runtime']){$canonical['Runtime']=Get-WsmQualificationRuntimeProjection $Tuple.Runtime}
    Get-WsmHashText (($canonical | ConvertTo-Json -Depth 8 -Compress))
}
function Get-WsmHashBytes([byte[]]$Bytes) { $sha=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()} }
function Get-WsmQualificationRecordKey {
    [CmdletBinding()]param([Parameter(Mandatory)][ValidateNotNull()]$Tuple)
    Get-WsmQualificationKey $Tuple
}
function Get-WsmQualificationSigningBytes($Record) {
    $projection=[ordered]@{SchemaVersion=[int]$Record.SchemaVersion;ToolVersion=[string]$Record.ToolVersion;Kind=[string]$Record.Kind;QualificationId=[string]$Record.QualificationId;Key=[string]$Record.Key;Tuple=$Record.Tuple;ReleaseDecision=[string]$Record.ReleaseDecision;Requirements=$Record.Requirements;Evidence=@($Record.Evidence);CreatedUtc=[string]$Record.CreatedUtc;CreatedBy=[string]$Record.CreatedBy}
    [Text.Encoding]::UTF8.GetBytes(($projection | ConvertTo-Json -Depth 20 -Compress))
}
function New-WsmQualificationSigningRequest {
    [CmdletBinding()]param([Parameter(Mandatory)]$Tuple,[Parameter(Mandatory)]$Requirements,[Parameter(Mandatory)][object[]]$Evidence,[Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CreatedBy,[Parameter(Mandatory)][string]$Path)
    if(-not $Tuple.PSObject.Properties['ReleaseArtifact']){throw 'Production qualification must bind the exact signed release archive and signature hashes.'}
    if(-not $Tuple.PSObject.Properties['Runtime']){throw 'Production qualification requires exact source and target Runtime.'};Assert-WsmProductionRuntime $Tuple.Runtime
    $record=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='QualificationRecord';QualificationId=[Guid]::NewGuid().ToString();Key=(Get-WsmQualificationKey $Tuple);Tuple=$Tuple;ReleaseDecision='ProductionAccepted';Requirements=$Requirements;Evidence=@($Evidence);CreatedUtc=(Get-WsmUtc);CreatedBy=$CreatedBy;Trust=$null}
    [void](Assert-WsmQualificationRecord $record -AllowPendingTrust);$bytes=Get-WsmQualificationSigningBytes $record;$fullPath=[IO.Path]::GetFullPath($Path);if([IO.File]::Exists($fullPath)){throw 'Qualification signing request output already exists.'};$directory=[IO.Path]::GetDirectoryName($fullPath);if(-not [IO.Directory]::Exists($directory)){[void][IO.Directory]::CreateDirectory($directory)};$temporary=$fullPath+'.'+[Guid]::NewGuid().ToString('N')+'.partial';try{$stream=[IO.File]::Open($temporary,'CreateNew','Write','None');try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()};[IO.File]::Move($temporary,$fullPath)}finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
    [pscustomobject]@{Path=[IO.Path]::GetFullPath($Path);SHA256=(Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant();SigningContentSHA256=(Get-WsmHashBytes $bytes);SigningContentBase64=[Convert]::ToBase64String($bytes);QualificationId=$record.QualificationId;Key=$record.Key;NextStep='Sign these exact bytes with the enterprise QualificationApprover certificate, then complete with the signature and independently supplied trust policy hash.'}
}
function Complete-WsmQualificationSigningRequest {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RequestPath,[Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$RequestHash,[Parameter(Mandatory)][string]$SignaturePath,[Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$SignatureHash,[Parameter(Mandatory)][string]$ReleasePath,[Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ReleaseHash,[Parameter(Mandatory)][string]$ReleaseSignaturePath,[Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ReleaseSignatureHash,[Parameter(Mandatory)][string]$TrustPolicyPath,[Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$TrustPolicyHash)
    $request=Read-WsmTrustedJson $RequestPath $RequestHash;$requestTrust=$request.PSObject.Properties['Trust'];if($request.SchemaVersion -ne 1 -or $request.ReleaseDecision -cne 'ProductionAccepted' -or ($null -ne $requestTrust -and $null -ne $requestTrust.Value)){throw 'Invalid or already completed qualification signing request.'}
    if(-not $request.Tuple.PSObject.Properties['Runtime']){throw 'Production qualification requires exact source and target Runtime.'};Assert-WsmProductionRuntime $request.Tuple.Runtime
    $bytes=Get-WsmQualificationSigningBytes $request;$actual=(Get-WsmHashBytes $bytes);$stored=[IO.File]::ReadAllBytes([IO.Path]::GetFullPath($RequestPath));if((Get-WsmHashBytes $stored) -cne $actual){throw 'Qualification request bytes are not the exact canonical signing content.'}
    $release=Test-WsmToolRelease -Path $ReleasePath -ExpectedHash $ReleaseHash -SignaturePath $ReleaseSignaturePath -ExpectedSignatureHash $ReleaseSignatureHash -TrustPolicyPath $TrustPolicyPath -TrustPolicyHash $TrustPolicyHash;$artifact=$request.Tuple.ReleaseArtifact;if($artifact.ArchiveSHA256 -ine $release.SHA256 -or $artifact.SignatureSHA256 -ine $release.SignatureSHA256 -or $artifact.ToolFingerprint -ine $release.ToolFingerprint -or $artifact.SignerThumbprint -ine $release.SignerThumbprint -or $artifact.TrustPolicyHash -ine $release.TrustPolicyHash){throw 'Qualification request release artifact does not match the verified final signed release.'}
    if(-not [IO.File]::Exists($SignaturePath) -or (Get-FileHash -LiteralPath $SignaturePath).Hash -ine $SignatureHash){throw 'Qualification signature bytes differ from the supplied expected hash.'}
    $verification=Assert-WsmDetachedCmsSignature -ContentBytes $bytes -SignatureBytes ([IO.File]::ReadAllBytes([IO.Path]::GetFullPath($SignaturePath))) -TrustPolicyPath $TrustPolicyPath -TrustPolicyHash $TrustPolicyHash -Role QualificationApprover
    $request | Add-Member NoteProperty Trust ([pscustomobject][ordered]@{SignatureBase64=[Convert]::ToBase64String([IO.File]::ReadAllBytes([IO.Path]::GetFullPath($SignaturePath)));SignatureSHA256=$SignatureHash.ToLowerInvariant();SigningContentSHA256=$actual;SignerThumbprint=$verification.SignerThumbprint;RootThumbprint=$verification.RootThumbprint;TrustPolicyHash=$TrustPolicyHash.ToLowerInvariant();VerifiedUtc=$verification.VerifiedUtc;TrustBasis=$verification.TrustBasis}) -Force
    [void](Assert-WsmQualificationRecord $request);$request
}
function New-WsmQualificationRecord {
    [CmdletBinding()]param([Parameter(Mandatory)][ValidateNotNull()]$Tuple,[Parameter(Mandatory)][ValidateSet('PilotOnly','ProductionAccepted')][string]$ReleaseDecision,[Parameter(Mandatory)][ValidateNotNull()]$Requirements,[Parameter(Mandatory)][ValidateNotNull()][object[]]$Evidence,[Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CreatedBy)
    if($ReleaseDecision -eq 'ProductionAccepted'){throw 'ProductionAccepted records require New-WsmQualificationSigningRequest and a detached enterprise signature.'}
    $record=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='QualificationRecord';QualificationId=[Guid]::NewGuid().ToString();Key=(Get-WsmQualificationKey $Tuple);Tuple=$Tuple;ReleaseDecision=$ReleaseDecision;Requirements=$Requirements;Evidence=$Evidence;CreatedUtc=(Get-WsmUtc);CreatedBy=$CreatedBy;Trust=$null}
    [void](Assert-WsmQualificationRecord $record);$record
}
function Assert-WsmQualificationRecord($Record,[switch]$AllowPendingTrust) {
    Assert-WsmEnvelope $Record QualificationRecord
    Assert-WsmFields $Record @('SchemaVersion','ToolVersion','Kind','QualificationId','Key','Tuple','ReleaseDecision','Requirements','Evidence','CreatedUtc','CreatedBy','Trust') @('QualificationId','Key','Tuple','ReleaseDecision','Requirements','Evidence','CreatedUtc','CreatedBy')
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
    if($Record.ReleaseDecision -eq 'ProductionAccepted') {
        $trustProperty=$Record.PSObject.Properties['Trust'];$hasTrust=$false;if($null -ne $trustProperty){$hasTrust=$null -ne $trustProperty.Value}
        if($hasTrust -or $AllowPendingTrust){foreach($side in @('Source','Target')){if(-not $Record.Tuple.$side.PSObject.Properties['InstallationType']){throw ('Production qualification requires exact '+$side+' InstallationType.')}};if(-not $Record.Tuple.PSObject.Properties['ReleaseArtifact']){throw 'Production qualification must bind the exact signed release artifact.'};if($Record.Tuple.Adapter -match 'Oracle' -or $Record.Tuple.Product -match '(?i)Oracle|ODAC|ODP\.NET' -or $Record.Tuple.PSObject.Properties['OracleProvider']){if(-not $Record.Tuple.PSObject.Properties['OracleProvider'] -or -not $Record.Tuple.PSObject.Properties['OracleConsumer']){throw 'Oracle qualification requires exact provider and consumer scope.'}}}
        if($hasTrust){Assert-WsmFields $Record.Trust @('SignatureBase64','SignatureSHA256','SigningContentSHA256','SignerThumbprint','RootThumbprint','TrustPolicyHash','VerifiedUtc','TrustBasis') @('SignatureBase64','SignatureSHA256','SigningContentSHA256','SignerThumbprint','RootThumbprint','TrustPolicyHash','VerifiedUtc','TrustBasis');foreach($field in @('SignatureSHA256','SigningContentSHA256','TrustPolicyHash')){if([string]$Record.Trust.$field -notmatch '^[a-f0-9]{64}$'){throw ('Invalid trust '+$field+'.')}};if([string]$Record.Trust.SignatureBase64.Length -gt 6000000){throw 'Qualification signature exceeds its size limit.'};[void](Convert.FromBase64String([string]$Record.Trust.SignatureBase64));Assert-WsmQualificationText ([string]$Record.Trust.SignerThumbprint) SignerThumbprint 128;Assert-WsmQualificationText ([string]$Record.Trust.RootThumbprint) RootThumbprint 128;[void](ConvertTo-WsmQualificationUtc ([string]$Record.Trust.VerifiedUtc) TrustVerifiedUtc)}
    }
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
function Assert-WsmQualificationRevocationPolicy {
    param([string]$Path,[string]$SHA256,[string]$QualificationId)
    $policy=Read-WsmTrustedJson $Path $SHA256;Assert-WsmEnvelope $policy EnterpriseTrustPolicy
    if(-not $policy.PSObject.Properties['QualificationRevocations']){throw 'Enterprise policy lacks the authoritative qualification revocation ledger.'}
    $rows=@($policy.QualificationRevocations);if($rows.Count -gt 10000){throw 'Enterprise qualification revocation ledger exceeds its bound.'};$seen=@{}
    foreach($row in $rows){Assert-WsmFields $row @('QualificationId','Owner','Reference','RevokedUtc') @('QualificationId','Owner','Reference','RevokedUtc');Assert-WsmId $row.QualificationId;Assert-WsmQualificationText ([string]$row.Owner) RevocationOwner 256;Assert-WsmQualificationText ([string]$row.Reference) RevocationReference 1024;$utc=ConvertTo-WsmQualificationUtc ([string]$row.RevokedUtc) RevokedUtc;if($utc -gt [DateTimeOffset]::UtcNow.AddMinutes(5) -or $seen.ContainsKey([string]$row.QualificationId)){throw 'Enterprise qualification revocation row has a duplicate ID or future time.'};$seen[[string]$row.QualificationId]=$true}
    if($seen.ContainsKey($QualificationId)){throw 'Qualification was revoked by the independently pinned enterprise policy.'}
}
function Test-WsmQualificationTrust {
    param([Parameter(Mandatory)]$Record,[string]$TrustPolicyPath,[string]$TrustPolicyHash)
    if($Record.ReleaseDecision -ne 'ProductionAccepted'){return [pscustomobject]@{Valid=$true;Blocked=$false;Reason='PilotOnly does not authorize production.'}}
    if([string]::IsNullOrWhiteSpace($TrustPolicyPath) -or [string]::IsNullOrWhiteSpace($TrustPolicyHash)){return [pscustomobject]@{Valid=$false;Blocked=$true;Reason='Independent enterprise trust policy was not supplied.'}}
    $trustProperty=$Record.PSObject.Properties['Trust'];if($null -eq $trustProperty -or $null -eq $trustProperty.Value){return [pscustomobject]@{Valid=$false;Blocked=$true;Reason='Legacy or unsigned qualification has no independent enterprise attestation.'}}
    if(-not $Record.Tuple.PSObject.Properties['Runtime']){return [pscustomobject]@{Valid=$false;Blocked=$true;Reason='Legacy qualification lacks exact source and target runtime scope.'}};Assert-WsmProductionRuntime $Record.Tuple.Runtime
    [void](Assert-WsmQualificationRecord $Record);if($TrustPolicyHash -ine [string]$Record.Trust.TrustPolicyHash){throw 'Qualification trust policy hash changed; re-sign and reapprove the record.'}
    Assert-WsmQualificationRevocationPolicy $TrustPolicyPath $TrustPolicyHash $Record.QualificationId
    $bytes=Get-WsmQualificationSigningBytes $Record;$contentHash=Get-WsmHashBytes $bytes;if($contentHash -cne [string]$Record.Trust.SigningContentSHA256){throw 'Signed qualification projection changed after approval.'}
    $signature=[Convert]::FromBase64String([string]$Record.Trust.SignatureBase64);if((Get-WsmHashBytes $signature) -cne [string]$Record.Trust.SignatureSHA256){throw 'Stored qualification signature bytes changed.'}
    $verified=Assert-WsmDetachedCmsSignature -ContentBytes $bytes -SignatureBytes $signature -TrustPolicyPath $TrustPolicyPath -TrustPolicyHash $TrustPolicyHash -Role QualificationApprover
    if($verified.SignerThumbprint -cne [string]$Record.Trust.SignerThumbprint -or $verified.RootThumbprint -cne [string]$Record.Trust.RootThumbprint){throw 'Current enterprise signer/root differs from the recorded trust attestation.'}
    [pscustomobject]@{Valid=$true;Blocked=$false;Reason='Independent enterprise signature and current policy verified.';Trust=$verified}
}
function Add-WsmQualification {
    [CmdletBinding()]param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,[Parameter(Mandatory)][ValidateNotNull()]$Record,[string]$TrustPolicyPath,[string]$TrustPolicyHash)
    [void](Assert-WsmQualificationRecord $Record);if($Record.ReleaseDecision -eq 'ProductionAccepted'){$trust=Test-WsmQualificationTrust $Record $TrustPolicyPath $TrustPolicyHash;if(-not $trust.Valid){throw $trust.Reason}};$directory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path));if(-not [IO.Directory]::Exists($directory)){[void][IO.Directory]::CreateDirectory($directory)}
    Invoke-WsmLocked $directory {if($Record.ReleaseDecision -eq 'ProductionAccepted'){$trust=Test-WsmQualificationTrust $Record $TrustPolicyPath $TrustPolicyHash;if(-not $trust.Valid){throw $trust.Reason}};$registry=Get-WsmQualificationRegistry $Path;if(@($registry.Records | Where-Object QualificationId -CEQ $Record.QualificationId).Count){throw 'Qualification ID already exists.'};$prior=@($registry.Records | Where-Object Key -CEQ $Record.Key | Sort-Object @{Expression={ConvertTo-WsmQualificationUtc ([string]$_.CreatedUtc) CreatedUtc}} -Descending | Select-Object -First 1);if($prior.Count -and (ConvertTo-WsmQualificationUtc ([string]$Record.CreatedUtc) CreatedUtc) -le (ConvertTo-WsmQualificationUtc ([string]$prior[0].CreatedUtc) CreatedUtc)){throw 'Qualification revisions for an exact tuple must have increasing creation times.'};$registry.Records=@($registry.Records)+@($Record);Write-WsmJson $Path $registry;[pscustomobject]@{Path=[IO.Path]::GetFullPath($Path);QualificationId=$Record.QualificationId;Key=$Record.Key;ReleaseDecision=$Record.ReleaseDecision}}
}
function Revoke-WsmQualification {
    [CmdletBinding()]param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,[Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$QualificationId,[Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Owner,[Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Reference)
    Assert-WsmId $QualificationId;Assert-WsmQualificationText $Owner Owner 256;Assert-WsmQualificationText $Reference Reference 1024;$directory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    Invoke-WsmLocked $directory {$registry=Get-WsmQualificationRegistry $Path;if(-not @($registry.Records | Where-Object QualificationId -CEQ $QualificationId).Count){throw 'Unknown qualification ID.'};if(@($registry.Revocations | Where-Object QualificationId -CEQ $QualificationId).Count){throw 'Qualification is already revoked.'};$registry.Revocations=@($registry.Revocations)+@([pscustomobject]@{QualificationId=$QualificationId;Owner=$Owner;Reference=$Reference;Utc=(Get-WsmUtc)});Write-WsmJson $Path $registry;[pscustomobject]@{QualificationId=$QualificationId;Revoked=$true;RevocationScope='LocalRegistryOnly';EnterpriseRevocationRequired=$true}}
}
function Get-WsmQualification {
    [CmdletBinding()]param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,[Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$Key)
    $registry=Get-WsmQualificationRegistry $Path;$matches=@($registry.Records | Where-Object Key -CEQ $Key | Sort-Object @{Expression={ConvertTo-WsmQualificationUtc ([string]$_.CreatedUtc) CreatedUtc}} -Descending);if(-not $matches.Count){return $null};$record=$matches[0];$revoked=@($registry.Revocations | Where-Object QualificationId -CEQ $record.QualificationId).Count -gt 0
    [pscustomobject]@{Record=$record;Revoked=$revoked}
}
function Resolve-WsmProductionQualification {
    [CmdletBinding()]param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,[Parameter(Mandatory)][ValidateNotNull()]$Tuple,[string]$TrustPolicyPath,[string]$TrustPolicyHash)
    $key=Get-WsmQualificationKey $Tuple;$found=Get-WsmQualification $Path $key;$problems=New-Object 'System.Collections.Generic.List[string]'
    if(-not $found){$problems.Add('No exact tool/adapter/source/target/product qualification exists.');return [pscustomobject]@{Qualified=$false;Key=$key;Record=$null;Problems=$problems.ToArray()}}
    $r=$found.Record;if($found.Revoked){$problems.Add('Qualification was revoked.')};if($r.ReleaseDecision -ne 'ProductionAccepted'){$problems.Add('Release decision is not ProductionAccepted.')};if($r.ReleaseDecision -eq 'ProductionAccepted'){try{$trust=Test-WsmQualificationTrust $r $TrustPolicyPath $TrustPolicyHash;if(-not $trust.Valid){$problems.Add($trust.Reason)}}catch{$problems.Add(('Independent enterprise trust failed: '+$_.Exception.Message))}}
    $now=[DateTimeOffset]::UtcNow;foreach($e in $r.Evidence){if((ConvertTo-WsmQualificationUtc ([string]$e.ExpiresUtc) ExpiresUtc) -le $now){$problems.Add(('Evidence expired: '+$e.Type))};if((ConvertTo-WsmQualificationUtc ([string]$e.ObservedUtc) ObservedUtc) -gt $now.AddMinutes(5)){$problems.Add(('Evidence observation is in the future: '+$e.Type))}}
    foreach($type in @('ServerLab','IsolatedPilot','ProductionAcceptance')){if(@($r.Evidence | Where-Object {$_.Type -ceq $type -and (ConvertTo-WsmQualificationUtc ([string]$_.ExpiresUtc) ExpiresUtc) -gt $now}).Count -eq 0){$problems.Add(('Current '+$type+' evidence missing.'))}}
    [pscustomobject]@{Qualified=($problems.Count -eq 0);Key=$key;Record=$r;Problems=$problems.ToArray()}
}
function Get-WsmQualificationMatrix {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RegistryPath,[Parameter(Mandatory)][string]$TuplesPath,[Parameter(Mandatory)][string]$TuplesHash,[string]$OutputPath,[string]$TrustPolicyPath,[string]$TrustPolicyHash)
    $input=Read-WsmTrustedJson $TuplesPath $TuplesHash;Assert-WsmFields $input @('Tuples') @('Tuples');if(@($input.Tuples).Count -gt 10000){throw 'Qualification matrix exceeds 10000 reviewed tuples.'}
    $tool=Get-WsmToolFingerprint;$matrix=@{};foreach($capability in (Get-WsmAdapterMatrix)){$matrix[$capability.Adapter]=$capability}
    $rows=@(foreach($tuple in $input.Tuples){[void](Get-WsmQualificationKey $tuple);if(-not $matrix.ContainsKey($tuple.Adapter)){throw 'Unknown adapter in qualification tuple.'};$resolved=Resolve-WsmProductionQualification -Path $RegistryPath -Tuple $tuple -TrustPolicyPath $TrustPolicyPath -TrustPolicyHash $TrustPolicyHash;$current=($tuple.ToolFingerprint -ieq $tool);[pscustomobject]@{Tuple=$tuple;InstalledToolMatches=$current;QualificationRecorded=($resolved.Qualified -and $current);EvidenceAssertion='Evidence and exact scope must be independently signed under the supplied enterprise trust policy';ExecutionMode='IsolatedPilot';ProductionExecutionEnabled=$false;Problems=@($resolved.Problems)+@($(if(-not $current){'Installed tool fingerprint differs.'}));Capability=$matrix[$tuple.Adapter];Requirements=$(if($resolved.Record){$resolved.Record.Requirements}else{$null})}})
    $result=[pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='QualificationMatrix';ProducedUtc=(Get-WsmUtc);ToolFingerprint=$tool;Rows=$rows;ProductionExecutionEnabled=$false}
    if($OutputPath){Write-WsmJson $OutputPath $result};$result
}
