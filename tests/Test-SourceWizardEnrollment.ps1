$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$script:ToolVersion='0.3.0'
$script:FixtureFingerprint='a'*64
$script:FixturePlan=$null
function Assert-SourceWizardTest([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-WsmId([string]$Id){$g=[Guid]::Empty;if(-not [Guid]::TryParseExact($Id,'D',[ref]$g)){throw 'bad id'}}
function Assert-WsmEnvelope($Data,[string]$Kind){if($Data.SchemaVersion -ne 1 -or $Data.Kind -cne $Kind){throw 'bad envelope'}}
function Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:FixtureFingerprint;Name='fixture';OS='Windows Server';Version='10';IsServer=$true;Administrator=$true;Is64Bit=$true}}
function Assert-WsmMigrationHost($Identity,[string]$Fingerprint){if($Identity.Fingerprint -cne $Fingerprint){throw 'fixture host mismatch'}}
function Assert-WsmNoReparse([string]$Path){$full=[IO.Path]::GetFullPath($Path);if($full.StartsWith($script:TestRoot,[StringComparison]::OrdinalIgnoreCase) -and $full -match '\\unsafe(?:\\|$)'){throw 'fixture reparse point'}}
function Protect-WsmDirectory([string]$Path){}
function Assert-WsmCancellationDirectoryProtection([string]$Path){}
function Get-WsmAvailableBytes([string]$Path){[long]2147483648}
function Get-WsmPhysicalPath([string]$Path){[IO.Path]::GetFullPath($Path)}
function Test-WsmPathOverlap([string]$Left,[string]$Right){$l=[IO.Path]::GetFullPath($Left).TrimEnd('\');$r=[IO.Path]::GetFullPath($Right).TrimEnd('\');$l -ieq $r -or $l.StartsWith($r+'\',[StringComparison]::OrdinalIgnoreCase) -or $r.StartsWith($l+'\',[StringComparison]::OrdinalIgnoreCase)}
function Read-WsmJson([string]$Path){ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8))}
function Write-WsmJson([string]$Path,$Data){$parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path));if(-not [IO.Directory]::Exists($parent)){[void][IO.Directory]::CreateDirectory($parent)};[IO.File]::WriteAllText($Path,($Data|ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false)))}
function Get-WsmUtc {[DateTime]::UtcNow.ToString('o')}
function Invoke-WsmLocked([string]$Workspace,[scriptblock]$Action){& $Action}
function Read-WsmMigrationPlan([string]$Path,[string]$ExpectedHash){if($ExpectedHash -ine ('f'*64)){throw 'fixture plan hash mismatch'};$script:FixturePlan}
. (Join-Path $PSScriptRoot '..\src\OutputWorkspace.ps1')
. (Join-Path $PSScriptRoot '..\src\MigrationWizard.ps1')
$script:TestRoot=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('.source-wizard-test-'+[Guid]::NewGuid().ToString('N'))))
[void][IO.Directory]::CreateDirectory($script:TestRoot)
try {
    $root=Join-Path $script:TestRoot 'source';$enrollment=Initialize-WsmOutputWorkspace -WorkRoot $root -Role Source
    $sourceStatePath=Join-Path $enrollment.InventoryDirectory 'source-state.json';$sourceState=Read-WsmJson $sourceStatePath;$sourceState.Revision=1;Write-WsmJson $sourceStatePath $sourceState
    $pair='11111111-1111-4111-8111-111111111111';$planHash='f'*64
    $script:FixturePlan=[pscustomobject]@{PairId=$pair;Source=[pscustomobject]@{Fingerprint=$script:FixtureFingerprint;HostId=$enrollment.HostId}}
    $attemptId='22222222-2222-4222-8222-222222222222'
    $resolved=Resolve-WsmSourceWizardWorkspace 'fixture-plan.json' $planHash $root $attemptId
    Assert-SourceWizardTest ($resolved.SourceStateDirectory -ceq $enrollment.InventoryDirectory) 'Source workflow did not use the enrolled inventory state root.'
    Assert-SourceWizardTest ($resolved.Attempt.PairRoot -ceq (Join-Path $root ('pairs\'+$pair))) 'Source workflow registered a different pair state root.'
    Assert-SourceWizardTest ($resolved.Attempt.PackagesDirectory -like ('*\attempts\'+$attemptId+'\packages') -and $resolved.Attempt.ScratchDirectory -like ('*\attempts\'+$attemptId+'\scratch')) 'Source attempt output paths were not resolved from the enrollment.'
    $again=Resolve-WsmSourceWizardWorkspace 'fixture-plan.json' $planHash $root $attemptId
    Assert-SourceWizardTest ($again.Attempt.AttemptId -ceq $attemptId -and $again.Attempt.PairRoot -ceq $resolved.Attempt.PairRoot) 'Explicit source retry changed attempt or pair identity.'
    $script:FixturePlan=[pscustomobject]@{PairId='33333333-3333-4333-8333-333333333333';Source=[pscustomobject]@{Fingerprint=('b'*64);HostId=$enrollment.HostId}}
    $blocked=$false;try{Resolve-WsmSourceWizardWorkspace 'fixture-plan.json' $planHash $root '' | Out-Null}catch{$blocked=$true}
    Assert-SourceWizardTest $blocked 'Source plan with another host fingerprint was accepted.'
    $script:FixturePlan=[pscustomobject]@{PairId='44444444-4444-4444-8444-444444444444';Source=[pscustomobject]@{Fingerprint=$script:FixtureFingerprint;HostId='55555555-5555-4555-8555-555555555555'}}
    $blocked=$false;try{Resolve-WsmSourceWizardWorkspace 'fixture-plan.json' $planHash $root '' | Out-Null}catch{$blocked=$true}
    Assert-SourceWizardTest $blocked 'Source plan with another enrolled HostId was accepted.'
    $missing=Join-Path $script:TestRoot 'missing-state';$missingEnrollment=Initialize-WsmOutputWorkspace -WorkRoot $missing -Role Source
    $script:FixturePlan=[pscustomobject]@{PairId='66666666-6666-4666-8666-666666666666';Source=[pscustomobject]@{Fingerprint=$script:FixtureFingerprint;HostId=$missingEnrollment.HostId}}
    $blocked=$false;try{Resolve-WsmSourceWizardWorkspace 'fixture-plan.json' $planHash $missing '' | Out-Null}catch{$blocked=$true}
    Assert-SourceWizardTest $blocked 'Unscanned Source enrollment with revision zero was accepted.'
    Write-Host 'Source wizard enrollment checks passed.'
} finally {
    $rootPath=[IO.Path]::GetFullPath($script:TestRoot);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $rootPath.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing source wizard fixture cleanup outside the temp test workspace.'}
    if([IO.Directory]::Exists($rootPath)){[IO.Directory]::Delete($rootPath,$true)}
}
