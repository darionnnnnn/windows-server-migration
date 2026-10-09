#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
. (Join-Path $PSScriptRoot 'ExternalReadinessEvidenceFixtures.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-source-recovery-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root);$workspace=Join-Path $root 'manager';$sourceState=Join-Path $root 'source';[void][IO.Directory]::CreateDirectory($sourceState);Initialize-WsmWorkspace $workspace | Out-Null
$source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='fixture-source'}
& $module {
    param($Source,$SourceRoot)
    . (Join-Path $PSScriptRoot 'Helper-Fixtures.ps1')
    $script:fixtureSupplement=New-WsmFixtureServiceSupplement
    $script:sourceFixture=$Source;$script:sourceRoot=$SourceRoot;$script:fixtureFingerprint=('a'*64);$script:sourceRevision=0;$script:sourceServices=@{}
    foreach($name in @('FixtureSourceOne','FixtureSourceTwo')){$script:sourceServices[$name]=[pscustomobject]@{Name=$name;Mode='Auto';State='Running'}}
    function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:fixtureFingerprint;Name='fixture';OS='Fixture Server';Version='10.fixture';IsServer=$true;Administrator=$true;Is64Bit=$true}}
    function script:Get-CimInstance {param($ClassName)if($ClassName -ne 'Win32_Service'){throw 'Unexpected OS query'};foreach($s in $script:sourceServices.Values){[pscustomobject]@{Name=$s.Name;StartMode=$s.Mode;State=$s.State}}}
    function script:Set-Service {param($Name,$StartupType)$mode=$StartupType;if($mode -eq 'Automatic'){$mode='Auto'};$script:sourceServices[$Name].Mode=$mode}
    function script:Stop-Service {param($Name,$ErrorAction)if($Name -ceq $script:stopFaultName){throw 'Injected source stop failure'};$script:sourceServices[$Name].State='Stopped'}
    function script:Start-Service {param($Name)$script:sourceServices[$Name].State='Running'}
    function script:Export-WsmInventory {
        param($OutputDirectory,[switch]$DeepDiscovery)
        $script:sourceRevision++;$items=@(foreach($s in ($script:sourceServices.Values | Sort-Object Name)){New-WsmItem $script:sourceFixture.HostId Services Service $s.Name $s.Name ([ordered]@{Name=$s.Name;DisplayName=$s.Name;Description='fixture';PathName='C:\Fixture\service.exe';StartMode=$s.Mode;StartName='LocalSystem';ServiceType='Own Process';Supplement=$script:fixtureSupplement})})
        $inventory=New-WsmInventory $script:sourceFixture $script:sourceRevision $items;$path=Join-Path $OutputDirectory ('inventory-'+$script:sourceRevision+'.json');Write-WsmJson $path $inventory;[pscustomobject]@{Path=$path;SHA256=(Get-FileHash -LiteralPath $path).Hash}
    }
    $script:stopFaultName=''
} $source $sourceState
$first=& $module {Export-WsmInventory $script:sourceRoot};$c=Import-WsmInventory $workspace $first.Path $first.SHA256 target
Set-WsmDecision $workspace $c.PairId @($c.Items | ForEach-Object ItemId) Include reviewed 0 | Out-Null
$bundlePath=Join-Path $root 'specs.json';Export-WsmMigrationSpecBundle $workspace $c.PairId $bundlePath | Out-Null;$bundle=Get-Content $bundlePath -Raw | ConvertFrom-Json;foreach($r in $bundle.Rows){$r.MigrationSpec.Owner='fixture owner';$r.MigrationSpec.Evidence='source recovery fixture review'};[IO.File]::WriteAllText($bundlePath,($bundle | ConvertTo-Json -Depth 30));Import-WsmMigrationSpecBundle $workspace $c.PairId $bundlePath (Get-FileHash $bundlePath).Hash 1 APPLY-SPECS | Out-Null
& $module {$script:fixtureFingerprint=('b'*64)};$identity=Register-WsmTarget (Join-Path $root 'target-state') (Join-Path $root 'target.json');$planPath=Join-Path $root 'plan.json';$approval=Approve-WsmMigrationPlan $workspace $c.PairId $identity.Path $identity.SHA256 $planPath 2 ISOLATED-PILOT
& $module {param($Path,$Hash)$script:fixtureFingerprint=('a'*64);$plan=Read-WsmMigrationPlan $Path $Hash;$order=@(Get-WsmRestoreOrder $plan.Items);[array]::Reverse($order);$script:stopFaultName=$order[1].NaturalKey} $planPath $approval.SHA256
$approvedPlan=& $module {param($Path,$Hash)Read-WsmMigrationPlan $Path $Hash} $planPath $approval.SHA256;$freezeProof=New-WsmSourceFreezeEvidenceFixture -Plan $approvedPlan -PlanHash $approval.SHA256 -Root $root -Owner owner
$freezePath=Join-Path $root 'freeze.json';$failed=$false;try{Export-WsmFreezeRecord $planPath $approval.SHA256 $freezePath owner 'fixture writers drained' OWNER-CONFIRMED-QUIESCENCE -SourceStateDirectory $sourceState -FreezeExternalEvidencePath $freezeProof.Path -FreezeExternalEvidenceHash $freezeProof.SHA256 -FreezeEpoch $freezeProof.FreezeEpoch | Out-Null}catch{$failed=$true};if(-not $failed -or (Test-Path $freezePath)){throw 'Partial source failure incorrectly produced handoff'}
$attempts=@(Get-ChildItem -LiteralPath $sourceState -Filter attempt.json -Recurse);if($attempts.Count -ne 1){throw 'Interrupted source attempt not retained'};$attempt=Get-Content $attempts[0].FullName -Raw | ConvertFrom-Json;if($attempt.Status -ne 'Interrupted' -or $attempt.Items.Count -ne 2){throw 'Original source runtime evidence missing'}
& $module {$script:stopFaultName=''}
$retryFreezeProof=New-WsmSourceFreezeEvidenceFixture -Plan $approvedPlan -PlanHash $approval.SHA256 -Root $root -Owner owner;$freeze=Export-WsmFreezeRecord $planPath $approval.SHA256 $freezePath owner 'fixture retry with original baseline' OWNER-CONFIRMED-QUIESCENCE -SourceStateDirectory $sourceState -PreviousAttemptPath $attempts[0].FullName -PreviousAttemptHash (Get-FileHash $attempts[0].FullName).Hash -FreezeExternalEvidencePath $retryFreezeProof.Path -FreezeExternalEvidenceHash $retryFreezeProof.SHA256 -FreezeEpoch $retryFreezeProof.FreezeEpoch
if(-not $freeze.SourceAttemptPath){throw 'Successful source retry did not retain original recovery reference'}
$approvedPlan=& $module {param($Path,$Hash)Read-WsmMigrationPlan $Path $Hash} $planPath $approval.SHA256;$attemptState=Get-Content -LiteralPath $freeze.SourceAttemptPath -Raw|ConvertFrom-Json;$resumeProof=New-WsmSourceResumeEvidenceFixture -Plan $approvedPlan -PlanHash $approval.SHA256 -AttemptId $attemptState.AttemptId -AttemptHash $freeze.SourceAttemptHash -Root $root -Owner owner
$blocked=$false;try{Invoke-WsmSourceResume $planPath $approval.SHA256 $freeze.SourceAttemptPath $freeze.SourceAttemptHash $sourceState owner 'must confirm sole-writer ownership' WRONG -ResumeExternalEvidencePath $resumeProof.Path -ResumeExternalEvidenceHash $resumeProof.SHA256 | Out-Null}catch{$blocked=$true};if(-not $blocked){throw 'Source resumed without explicit ownership gate'}
$result=Invoke-WsmSourceResume $planPath $approval.SHA256 $freeze.SourceAttemptPath $freeze.SourceAttemptHash $sourceState owner 'fixture target stopped and data reconciled' ('SOURCE-OWNERSHIP-RESTORED '+$c.PairId) -ResumeExternalEvidencePath $resumeProof.Path -ResumeExternalEvidenceHash $resumeProof.SHA256
if($result.Status -ne 'SourceResumed'){throw 'Source restoration did not complete'}
& $module {foreach($s in $script:sourceServices.Values){if($s.Mode -ne 'Auto' -or $s.State -ne 'Running'){throw 'Original source runtime lost after partial retry'}}}
Write-Host ('PASS: partial source stop retains original baseline, retry reconciles only quiescence changes, explicit sole-writer gate and original runtime restoration. All service APIs are fixtures. Evidence: '+$root)
