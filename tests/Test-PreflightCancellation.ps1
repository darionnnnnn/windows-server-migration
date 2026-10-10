#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$originalTemp=$env:TEMP;$originalTmp=$env:TMP
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-preflight-cancel-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
try {
    # ScopeDigest uses Path.GetTempPath(). Isolate it per test process so concurrent
    # tests cannot make a global-temp scratch leak check fail spuriously.
    $isolatedTemp=Join-Path $root 'isolated-temp';[void][IO.Directory]::CreateDirectory($isolatedTemp);$env:TEMP=$isolatedTemp;$env:TMP=$isolatedTemp
    $pair=[Guid]::NewGuid().ToString();$planHash='a'*64;$manifestHash='b'*64
    $state=Join-Path $root 'state';[void][IO.Directory]::CreateDirectory($state)
    $scope=Join-Path $root 'business-scope';[void][IO.Directory]::CreateDirectory($scope)
    $file=Join-Path $scope 'payload.bin';$bytes=New-Object byte[] 131072;for($i=0;$i -lt $bytes.Length;$i++){$bytes[$i]=[byte]($i%251)};[IO.File]::WriteAllBytes($file,$bytes)
    $packageRoot=Join-Path $root 'package';[void][IO.Directory]::CreateDirectory($packageRoot)
    $item=[pscustomobject]@{ItemId='fixture-item';Decision='Include';Name='fixture scope';MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=$scope;TargetPath=$scope;Metadata='DaclOwner';ConflictPolicy='ReplaceOwned';ExcludedRelativePaths=@();AclControlPolicy='AllowAutoInheritedUpgrade'}}
    $manifest=[pscustomobject]@{PairId=$pair;PlanHash=$planHash;Target=[pscustomobject]@{Fingerprint=('c'*64)};Generation=1;Bytes=([long]$bytes.Length);ArtifactsHash=('d'*64);BaseManifestHash=''}
    $plan=[pscustomobject]@{SchemaVersion=1;PairId=$pair;Items=@($item)}
    $package=[pscustomobject]@{Manifest=$manifest;Plan=$plan;Root=$packageRoot;SHA256=$manifestHash}
    $stateValue=[pscustomobject]@{Generation=1;ManifestHash=$manifestHash;Items=@([pscustomobject]@{ItemId=$item.ItemId;Status='Succeeded';ActualHash='placeholder'});PendingOperations=@()}
    & $module {
        param($Package,$StateValue)
        $script:preflightFixturePackage=$Package;$script:preflightFixtureState=$StateValue;$script:preflightCancelPhase='';$script:preflightCancelInjected=$false
        $script:preflightOriginalBoundary=(Get-Command Assert-WsmCancellationBoundary).ScriptBlock
        function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=('c'*64);Name='fixture';OS='Fixture';Version='1';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function script:Test-WsmMigrationPackage {param($ManifestPath,$ExpectedHash,$CancellationToken=$null);if($CancellationToken){Assert-WsmCancellationBoundary $CancellationToken 'PackageFixtureScan'};$script:preflightFixturePackage}
        function script:Assert-WsmWorkspaceSeparation {param($Plan,$Workspace,$ScopeField)}
        function script:Assert-WsmSourceWorkspaceSeparation {param($Plan,$Workspace)}
        function script:Get-WsmOperationState {param($Paths,$Package);$script:preflightFixtureState}
        function script:Assert-WsmCancellationBoundary {param($Token,$Phase)
            if($Token -and $Phase -ceq $script:preflightCancelPhase -and -not $script:preflightCancelInjected){$script:preflightCancelInjected=$true;Request-WsmCancellation $Token 'Fixture owner' ('cancel at '+$Phase) | Out-Null}
            & $script:preflightOriginalBoundary $Token $Phase
        }
    } $package $stateValue
    $token=New-WsmCancellationToken $pair $planHash $manifestHash ([Guid]::NewGuid().ToString()) $state
    $before=(Get-FileHash -LiteralPath $file).Hash
    $digestTemp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\');$isolatedDigestTemp=[IO.Path]::GetFullPath($isolatedTemp).TrimEnd('\')
    if($digestTemp -ine $isolatedDigestTemp){throw 'Test process did not switch to its isolated digest temporary directory.'}
    $scratchBefore=@(Get-ChildItem -LiteralPath $isolatedTemp -Directory -Filter 'wsm-digest-*' | ForEach-Object FullName)
    & $module {$script:preflightCancelPhase='ScopeDigestHashBuffer';$script:preflightCancelInjected=$false}
    $cancelled=$false
    try {Get-WsmRestorePreview 'fixture-manifest' $manifestHash $state @{} $token | Out-Null} catch {$cancelled=$_.Exception -is [OperationCanceledException] -and $_.Exception.Data['CancellationBoundary'] -ceq 'ScopeDigestHashBuffer'}
    if(-not $cancelled){throw 'Restore preview swallowed or missed cancellation during a real file hash.'}
    if((Get-FileHash -LiteralPath $file).Hash -cne $before -or [IO.File]::ReadAllBytes($file).Length -ne $bytes.Length){throw 'Cancelled read-only preview changed business bytes.'}
    $scratchAfter=@(Get-ChildItem -LiteralPath $isolatedTemp -Directory -Filter 'wsm-digest-*' | ForEach-Object FullName)
    $scratch=@($scratchAfter | Where-Object {$_ -notin $scratchBefore})
    if($scratch.Count){throw ('Cancelled scope digest left its generated scratch directory: '+($scratch -join ', '))}
    if([IO.File]::Exists((Join-Path (Join-Path $state $pair) 'journal.jsonl'))){throw 'Cancelled read-only preview wrote a restore journal.'}

    $wrongState=Join-Path $root 'wrong-state';$wrong=New-WsmCancellationToken $pair $planHash ('e'*64) ([Guid]::NewGuid().ToString()) $wrongState
    $rejected=$false;try{Get-WsmRestorePreview 'fixture-manifest' $manifestHash $wrongState @{} $wrong | Out-Null}catch{$rejected=$_.Exception.Message -match 'Cancellation token is not bound'}
    if(-not $rejected -or [IO.Directory]::Exists($wrongState)){throw 'Restore preview accepted a token with the wrong manifest binding or mutated state before rejecting it.'}

    & $module {$script:preflightCancelPhase='';$script:preflightCancelInjected=$false;$script:preflightFixturePackage.Plan.Items=@([pscustomobject]@{ItemId='manual-item';Decision='Include';Name='manual';MigrationSpec=[pscustomobject]@{Adapter='ManualWorkflow';Procedure='fixture'}});$script:preflightFixtureState.Items=@();$script:preflightFixtureState.ManifestHash=''}
    $legacy=Get-WsmRestorePreview 'fixture-manifest' $manifestHash $state
    if(-not $legacy -or $legacy.Rows.Count -ne 1 -or $legacy.Rows[0].Action -cne 'ManualProcedure'){throw 'Backward-compatible restore preview call failed.'}
    Write-Host 'PASS: restore preview cancellation propagates during buffered file hashing; temp scratch is cleaned, business bytes and journal remain unchanged, wrong token is rejected before state creation, and legacy positional preview remains valid.'
} finally {$env:TEMP=$originalTemp;$env:TMP=$originalTmp;Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
