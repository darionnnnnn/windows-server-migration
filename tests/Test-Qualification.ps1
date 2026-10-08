#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
& $module {
    . (Join-Path $PSScriptRoot '..\src\Qualification.ps1')
    function New-FixtureEvidence([string]$Type,[DateTime]$Expires) { $observed=[DateTime]::UtcNow.AddMinutes(-1);if($Expires -le $observed){$observed=$Expires.AddDays(-2)};[pscustomobject]@{EvidenceId=[Guid]::NewGuid().ToString();Type=$Type;Owner='qualification reviewer';Reference=('fixture://evidence/'+$Type);ObservedUtc=$observed.ToString('o');ExpiresUtc=$Expires.ToString('o');SHA256=('a'*64)} }
    function New-FixtureQualification($Tuple,[string[]]$Types,[DateTime]$Expires,[string]$Decision='ProductionAccepted') {
        $requirements=[pscustomobject]@{Permissions='Elevated local administrator; required module access';ConsistencyMethod='Owner-approved service quiescence and product consistency';RebootBehavior='Explicit reboot barrier and post-boot verification';SideEffects='Installer consumers disabled before activation';RollbackLevel='Owned objects removed; data reconciliation is manual'}
        $evidence=@(foreach($type in $Types){New-FixtureEvidence $type $Expires})
        New-WsmQualificationRecord -Tuple $Tuple -ReleaseDecision $Decision -Requirements $requirements -Evidence $evidence -CreatedBy 'qualification reviewer'
    }
    $root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-qualification-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root);$path=Join-Path $root 'qualification.json'
    try {
        $tuple=[pscustomobject][ordered]@{ToolFingerprint=(Get-WsmToolFingerprint);Adapter='Service';AdapterFingerprint=('2'*64);Source=[pscustomobject][ordered]@{Family='WindowsServer';Version='2016';Build='14393';Edition='Standard';Architecture='x64'};Target=[pscustomobject][ordered]@{Family='WindowsServer';Version='2025';Build='26100';Edition='Standard';Architecture='x64'};Product='ExampleService';ProductVersion='4.2.1'}
        $future=[DateTime]::UtcNow.AddDays(30)
        $key=Get-WsmQualificationRecordKey -Tuple $tuple
        $reordered=[pscustomobject]@{ProductVersion=$tuple.ProductVersion;Product=$tuple.Product;Target=$tuple.Target;Source=$tuple.Source;AdapterFingerprint=$tuple.AdapterFingerprint;Adapter=$tuple.Adapter;ToolFingerprint=$tuple.ToolFingerprint};if((Get-WsmQualificationRecordKey -Tuple $reordered) -cne $key){throw 'Tuple property ordering changed its qualification key.'}
        $blocked=$false;try{Get-WsmQualificationRecordKey}catch{$blocked=$true};if(-not $blocked){throw 'Public key API accepted a missing tuple.'}
        $pilotPath=Join-Path $root 'pilot.json';$pilot=New-FixtureQualification $tuple @('Fixture') $future PilotOnly
        $pilotAdded=Add-WsmQualification -Path $pilotPath -Record $pilot;if($pilotAdded.QualificationId -cne $pilot.QualificationId){throw 'Qualification record was not added.'}
        $resolved=Resolve-WsmProductionQualification -Path $pilotPath -Tuple $tuple;if($resolved.Qualified -or -not ($resolved.Problems -contains 'Release decision is not ProductionAccepted.')){throw 'Fixture-only evidence qualified production.'}
        $blocked=$false;try{$null=New-FixtureQualification $tuple @('Fixture') $future ProductionAccepted}catch{$blocked=$true};if(-not $blocked){throw 'Mock evidence with a production release label passed schema validation.'}
        $complete=New-FixtureQualification $tuple @('ServerLab','IsolatedPilot','ProductionAcceptance') $future ProductionAccepted
        $added=Add-WsmQualification -Path $path -Record $complete;if($added.Key -cne $key){throw 'Created record key differs from public tuple key.'};$resolved=Resolve-WsmProductionQualification -Path $path -Tuple $tuple;if(-not $resolved.Qualified){throw ('Fully evidenced exact tuple did not resolve: '+($resolved.Problems -join '; '))}
        $stored=Get-WsmQualification -Path $path -Key $key;if($stored.Record.QualificationId -cne $complete.QualificationId -or $stored.Revoked){throw 'Exact qualification read returned wrong record or revocation state.'}
        $tupleFile=Join-Path $root 'tuples.json';Write-WsmJson $tupleFile ([pscustomobject]@{Tuples=@($tuple)});$tupleHash=(Get-FileHash -LiteralPath $tupleFile).Hash
        $matrix=Get-WsmQualificationMatrix -RegistryPath $path -TuplesPath $tupleFile -TuplesHash $tupleHash;if(-not $matrix.Rows[0].QualificationRecorded -or $matrix.ProductionExecutionEnabled -or $matrix.Rows[0].ProductionExecutionEnabled){throw 'Qualification matrix did not report the exact tuple while preserving execution lockout.'}
        $wrong=$tuple | ConvertTo-Json -Depth 8 | ConvertFrom-Json;$wrong.ToolFingerprint='3'*64;if((Resolve-WsmProductionQualification -Path $path -Tuple $wrong).Qualified){throw 'Tool fingerprint mismatch qualified.'}
        $wrong=$tuple | ConvertTo-Json -Depth 8 | ConvertFrom-Json;$wrong.Source.Build='99999';if((Resolve-WsmProductionQualification -Path $path -Tuple $wrong).Qualified){throw 'Source build mismatch qualified.'}
        $revoked=Revoke-WsmQualification -Path $path -QualificationId $complete.QualificationId -Owner 'release owner' -Reference 'fixture revocation ticket';if(-not $revoked.Revoked -or (Resolve-WsmProductionQualification -Path $path -Tuple $tuple).Qualified){throw 'Revoked qualification remained eligible.'}
        $matrix=Get-WsmQualificationMatrix -RegistryPath $path -TuplesPath $tupleFile -TuplesHash $tupleHash;if($matrix.Rows[0].QualificationRecorded -or $matrix.ProductionExecutionEnabled){throw 'Revoked tuple remained qualified in matrix or enabled execution.'}
        $expiredPath=Join-Path $root 'expired.json';$expired=New-FixtureQualification $tuple @('ServerLab','IsolatedPilot','ProductionAcceptance') ([DateTime]::UtcNow.AddSeconds(2)) ProductionAccepted;Add-WsmQualification -Path $expiredPath -Record $expired | Out-Null;Start-Sleep -Seconds 3;$result=Resolve-WsmProductionQualification -Path $expiredPath -Tuple $tuple;if($result.Qualified -or -not @($result.Problems | Where-Object {$_ -like 'Evidence expired:*'}).Count){throw 'Expired evidence qualified production.'}
        $blocked=$false;try{$null=New-FixtureQualification $tuple @('ServerLab','IsolatedPilot') $future ProductionAccepted}catch{$blocked=$true};if(-not $blocked){throw 'Production accepted record without ProductionAcceptance evidence passed schema validation.'}
        $bad=$complete | ConvertTo-Json -Depth 12 | ConvertFrom-Json;$bad.QualificationId=[Guid]::NewGuid().ToString();$bad.Key='0'*64;$blocked=$false;try{Add-WsmQualification -Path (Join-Path $root 'bad-key.json') -Record $bad | Out-Null}catch{$blocked=$true};if(-not $blocked){throw 'Tuple/key tampering accepted by registry producer.'}
        $futureRecord=New-FixtureQualification $tuple @('ServerLab','IsolatedPilot','ProductionAcceptance') $future ProductionAccepted;$futureRecord.CreatedUtc=[DateTime]::UtcNow.AddDays(1).ToString('o');$blocked=$false;try{Add-WsmQualification -Path (Join-Path $root 'future.json') -Record $futureRecord | Out-Null}catch{$blocked=$true};if(-not $blocked){throw 'Future-dated qualification record entered the registry.'}
        Write-Host 'PASS: exact tuple qualification lookup, fixture-only denial, ServerLab + isolated pilot + production acceptance contract, expiry/revocation/tool/build mismatch and strict key binding. Evidence values are contract fixtures, not real qualification.'
    } finally { if([IO.Directory]::Exists($root)){[IO.Directory]::Delete($root,$true)} }
}
