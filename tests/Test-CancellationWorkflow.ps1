#requires -Version 5.1
param([ValidateRange(0,10000)][int]$SmallFiles=0)
$ErrorActionPreference='Stop'
$pipelineWatch=[Diagnostics.Stopwatch]::StartNew()
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-cancel-workflow-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$sourceRoot=Join-Path $root 'source';$sourceState=Join-Path $root 'source-state';[void][IO.Directory]::CreateDirectory($sourceState);$targetRoot=Join-Path $root 'target';$packages=Join-Path $root 'packages';$workspace=Join-Path $root 'manager';$targetState=Join-Path $root 'target-state'
[void][IO.Directory]::CreateDirectory($sourceRoot);[void][IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'nested'));[void][IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'excluded'))
[IO.File]::WriteAllText((Join-Path $sourceRoot 'nested\unicode-中文.txt'),'initial fixture');[IO.File]::WriteAllText((Join-Path $sourceRoot 'excluded\not-selected.txt'),'never packaged')
$large=New-Object byte[] 2500000;for($n=0;$n -lt $large.Length;$n++){$large[$n]=[byte]($n%251)};[IO.File]::WriteAllBytes((Join-Path $sourceRoot 'chunked.bin'),$large)
if($SmallFiles){$smallRoot=Join-Path $sourceRoot 'small-files';[void][IO.Directory]::CreateDirectory($smallRoot);for($n=0;$n -lt $SmallFiles;$n++){[IO.File]::WriteAllText((Join-Path $smallRoot ('file-'+$n+'.txt')),('fixture bytes '+$n))}}
$source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='fixture-source'}
$item=New-WsmItem $source.HostId Storage DataRoot 'Approved data' 'approved-root' @{Path=$sourceRoot}
$inv=New-WsmInventory $source 1 @($item);$inventoryPath=Join-Path $root 'inventory.json';[IO.File]::WriteAllText($inventoryPath,($inv | ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)))
Initialize-WsmWorkspace $workspace | Out-Null;$catalog=Import-WsmInventory $workspace $inventoryPath (Get-FileHash $inventoryPath).Hash 'fixture-target';$pair=$catalog.PairId
# Only machine identity/collector are substituted; file bytes, ACLs, package hash and restore are real.
& $module {param($InventoryPath) $script:fixtureInventory=$InventoryPath;$script:fixtureFingerprint=('b'*64);function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:fixtureFingerprint;Name='fixture';OS='Fixture Server';Version='10.0.fixture';IsServer=$true;Administrator=$true;Is64Bit=$true}};function script:Export-WsmInventory {param($OutputDirectory)[pscustomobject]@{Path=$script:fixtureInventory;SHA256=(Get-FileHash -LiteralPath $script:fixtureInventory).Hash}}} $inventoryPath
$targetIdentity=Join-Path $root 'target-identity.json';$identity=Register-WsmTarget $targetState $targetIdentity
$spec=[pscustomobject]@{Adapter='FileScope';SourcePath=$sourceRoot;TargetPath=$targetRoot;ExcludedRelativePaths=@('excluded');Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='AllowAutoInheritedUpgrade';ConflictPolicy='ReplaceOwned';Owner='Fixture owner';Evidence='fixture-scope-review';BusinessChecks=@('Read expected fixture file')}
$specPath=Join-Path $root 'scope.json';[IO.File]::WriteAllText($specPath,($spec | ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
Set-WsmMigrationSpec $workspace $pair $item.ItemId $specPath (Get-FileHash $specPath).Hash 0
Set-WsmDecision $workspace $pair @($item.ItemId) Include 'fixture approved' 1 | Out-Null
$planPath=Join-Path $root 'plan.json';$approval=Approve-WsmMigrationPlan $workspace $pair $targetIdentity $identity.SHA256 $planPath 2 ISOLATED-PILOT
& $module {$script:fixtureFingerprint=('a'*64)}
$package=Export-WsmMigrationPackage $planPath $approval.SHA256 $sourceState $packages -ChunkBytes 65536
if(-not $package.Sealed -or $package.Files -ne (2+$SmallFiles) -or $package.Generation -ne 1){throw 'Initial package counters incorrect.'}
$verified=Test-WsmMigrationPackage $package.ManifestPath $package.SHA256
# Inject the user request through the real marker producer exactly at the chosen boundary.
& $module {
    $script:originalCancelBoundary=(Get-Command Assert-WsmCancellationBoundary).ScriptBlock
    $script:cancelAt='';$script:cancelInjected=$false
    function script:Assert-WsmCancellationBoundary {param($Token,$Phase)
        if($Token -and $Phase -ceq $script:cancelAt -and -not $script:cancelInjected){$script:cancelInjected=$true;Request-WsmCancellation $Token 'Fixture owner' ('request at '+$Phase) | Out-Null}
        & $script:originalCancelBoundary $Token $Phase
    }
}
function Select-CancelBoundary([string]$Phase) {& $module {param($Phase)$script:cancelAt=$Phase;$script:cancelInjected=$false} $Phase}
function Require-Cancellation([scriptblock]$Action,[string]$Phase) {$error=$null;try{& $Action | Out-Null}catch{$error=$_.Exception;if($error -isnot [OperationCanceledException]){Write-Host $_.ScriptStackTrace}};if($error -isnot [OperationCanceledException] -or $error.Data['CancellationBoundary'] -cne $Phase -or (Get-WsmFailureDetails $error).ExitCode -ne 3){throw ('Real workflow did not cancel at '+$Phase+'; actual: '+[string]$error)}}
& $module {
    param($Path,$Hash)
    $script:fixtureFingerprint='b'*64;$script:wizardPackageInputs=New-Object 'System.Collections.Generic.Queue[string]';$script:wizardPackageInputs.Enqueue($Path);$script:wizardPackageInputs.Enqueue($Hash)
    function script:Read-WsmWizardValue {param($Label,[switch]$Optional)if(-not $script:wizardPackageInputs.Count){throw 'Unexpected wizard prompt.'};$script:wizardPackageInputs.Dequeue()}
} $package.ManifestPath $package.SHA256
Select-CancelBoundary PackageIndexHashBuffer
Require-Cancellation {& $module {param($State)Read-WsmWizardRestorePackage $State} $targetState} PackageIndexHashBuffer
$wizardControls=@(Get-ChildItem -LiteralPath (Join-Path $targetState $pair) -Filter 'cancel-token-*.json')
if($wizardControls.Count -ne 1 -or [IO.File]::Exists((Join-Path (Join-Path $targetState $pair) 'journal.jsonl')) -or [IO.Directory]::Exists($targetRoot)){throw 'Wizard package preflight did not expose cancellation before read-only scanning, or changed target business state.'}
$wizardControl=Get-Content -LiteralPath $wizardControls[0].FullName -Raw | ConvertFrom-Json
if($wizardControl.ManifestHash -ine $package.SHA256 -or $wizardControl.PlanHash -ine $approval.SHA256){throw 'Wizard preflight token lost its trusted approved package binding.'}
& $module {$script:fixtureFingerprint='a'*64}
Select-CancelBoundary ''
$sourceToken=New-WsmCancellationToken $pair $approval.SHA256 '' ([Guid]::NewGuid().ToString()) $sourceState
$cancelPackages=Join-Path $root 'cancel-packages';Select-CancelBoundary PayloadChunkSealed
Require-Cancellation {Export-WsmMigrationPackage $planPath $approval.SHA256 $sourceState $cancelPackages -ChunkBytes 65536 -CancellationToken $sourceToken} PayloadChunkSealed
if(@(Get-ChildItem -LiteralPath $cancelPackages -Recurse -Filter manifest.json).Count -ne 0 -or @(Get-ChildItem -LiteralPath $cancelPackages -Recurse -Filter *.blob).Count -lt 1 -or @(Get-ChildItem -LiteralPath $cancelPackages -Recurse -Filter *.partial | Where-Object {$_.Directory.Name -ceq 'payload'}).Count){throw 'Cancelled source export sealed an incomplete package or lost retained verified chunks.'}
$cancelResult=Get-Content -LiteralPath (Join-Path (Join-Path $sourceState $pair) ('cancel-result-'+$sourceToken.OperationId+'.json')) -Raw | ConvertFrom-Json;if($cancelResult.Status -cne 'Cancelled' -or $cancelResult.Boundary -cne 'PayloadChunkSealed' -or -not $cancelResult.EffectsRetained){throw 'Source cancellation did not leave exact next-action evidence.'}
foreach($phase in @('PackageIndexHashBuffer','ArtifactIndexHashBuffer','PackageChunkHashBuffer','PackageWholeHashBuffer','ConfigIndexHashBuffer','ConfigArtifactRow')){
    $readToken=New-WsmCancellationToken $pair $approval.SHA256 $package.SHA256 ([Guid]::NewGuid().ToString()) $sourceState
    Select-CancelBoundary $phase
    Require-Cancellation {Test-WsmMigrationPackage $package.ManifestPath $package.SHA256 -CancellationToken $readToken} $phase
    if((Get-FileHash -LiteralPath $package.ManifestPath).Hash -ine $package.SHA256){throw 'Read-only cancellation changed sealed package bytes.'}
}
Select-CancelBoundary ''
# ZIP cancellation preserves sealed volumes and the controlled extraction workspace for explicit retry.
foreach($phase in @('ZipWriteBuffer','ZipVolumeHashBuffer','ZipMemberHashBuffer')){
    $bufferZip=Join-Path $root ('zip-buffer-'+$phase);[void][IO.Directory]::CreateDirectory($bufferZip)
    $bufferToken=New-WsmCancellationToken $pair $approval.SHA256 $package.SHA256 ([Guid]::NewGuid().ToString()) $bufferZip
    Select-CancelBoundary $phase
    Require-Cancellation {Export-WsmPackageZip $package.ManifestPath $package.SHA256 $bufferZip -VolumeBytes 1MB -CancellationToken $bufferToken} $phase
    if([IO.File]::Exists((Join-Path $bufferZip 'transport.json')) -or @(Get-ChildItem -LiteralPath $bufferZip -Filter *.zip).Count){throw 'Cancellation inside a ZIP stream sealed an unverified volume.'}
    Select-CancelBoundary ''
    $retryToken=New-WsmCancellationToken $pair $approval.SHA256 $package.SHA256 ([Guid]::NewGuid().ToString()) $bufferZip
    $retryZip=Export-WsmPackageZip $package.ManifestPath $package.SHA256 $bufferZip -VolumeBytes 1MB -CancellationToken $retryToken
    if(-not [IO.File]::Exists($retryZip.Path)){throw 'ZIP streaming cancellation could not retry to a complete transport.'}
}
$wrongZip=Join-Path $root 'wrong-token-output';$wrongZipToken=New-WsmCancellationToken $pair $approval.SHA256 $package.SHA256 ([Guid]::NewGuid().ToString()) (Join-Path $root 'different-output')
$wrongZipRejected=$false;try{Export-WsmPackageZip $package.ManifestPath $package.SHA256 $wrongZip -CancellationToken $wrongZipToken|Out-Null}catch{$wrongZipRejected=$_.Exception.Message -match 'Cancellation token is not bound'}
if(-not $wrongZipRejected -or [IO.Directory]::Exists($wrongZip)){throw 'ZIP export changed an output directory before checking cancellation scope.'}
$zipRoot=Join-Path $root 'zip';[void][IO.Directory]::CreateDirectory($zipRoot)
$zipToken=New-WsmCancellationToken $pair $approval.SHA256 $package.SHA256 ([Guid]::NewGuid().ToString()) $zipRoot
Select-CancelBoundary ZipVolumeCheckpoint
Require-Cancellation {Export-WsmPackageZip $package.ManifestPath $package.SHA256 $zipRoot -VolumeBytes 1MB -CancellationToken $zipToken} ZipVolumeCheckpoint
if([IO.File]::Exists((Join-Path $zipRoot 'transport.json')) -or @(Get-ChildItem -LiteralPath $zipRoot -Filter *.zip).Count -ne 1){throw 'ZIP cancellation lost a sealed volume or published incomplete transport.'}
Select-CancelBoundary ''
$zipToken=New-WsmCancellationToken $pair $approval.SHA256 $package.SHA256 ([Guid]::NewGuid().ToString()) $zipRoot
$transport=Export-WsmPackageZip $package.ManifestPath $package.SHA256 $zipRoot -VolumeBytes 1MB -CancellationToken $zipToken
$importRoot=Join-Path $root 'import';[void][IO.Directory]::CreateDirectory($importRoot)
$importToken=New-WsmCancellationToken $pair $approval.SHA256 $package.SHA256 ([Guid]::NewGuid().ToString()) $importRoot
Select-CancelBoundary ZipExtractBuffer
Require-Cancellation {Import-WsmPackageZip $transport.Path $transport.SHA256 $importRoot -CancellationToken $importToken} ZipExtractBuffer
Select-CancelBoundary ''
$importToken=New-WsmCancellationToken $pair $approval.SHA256 $package.SHA256 ([Guid]::NewGuid().ToString()) $importRoot
$imported=Import-WsmPackageZip $transport.Path $transport.SHA256 $importRoot -CancellationToken $importToken
Test-WsmMigrationPackage $imported.ManifestPath $imported.SHA256 | Out-Null
& $module {$script:fixtureFingerprint=('b'*64)}
foreach($phase in @('BeforeRestore','BeforeItem','RestoreChunkHashBuffer','RestoreChunkCopyBuffer','RestoreWholeHashBuffer','PayloadChunkRestored','AfterFileScopePrepared')){
    $token=New-WsmCancellationToken $pair $approval.SHA256 $package.SHA256 ([Guid]::NewGuid().ToString()) $targetState
    Select-CancelBoundary $phase
    Require-Cancellation {Invoke-WsmRestore $package.ManifestPath $package.SHA256 $targetState -CancellationToken $token} $phase
    $statePath=Join-Path (Join-Path $targetState $pair) 'state.json';$cancelled=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if($cancelled.Stage -cne 'Cancelled' -or -not (Test-WsmJournal $targetState $pair).Consistent){throw 'Target cancellation did not preserve a consistent durable checkpoint.'}
    $cancelledReceipt=Export-WsmStageResult $package.ManifestPath $package.SHA256 $targetState Restore (Join-Path $root ('cancelled-'+$phase+'.json'))
    if($cancelledReceipt.Result.Status -cne 'Cancelled' -or (Get-WsmOperationStatusCode $cancelledReceipt.Result) -ne 3){throw 'Cancelled restore was hidden behind a generic blocked result.'}
    if(Test-Path -LiteralPath $targetRoot){throw 'Cancellation before scope switch modified the live target.'}
    if($phase -cin @('RestoreChunkHashBuffer','RestoreChunkCopyBuffer','RestoreWholeHashBuffer','PayloadChunkRestored','AfterFileScopePrepared')){
        if($cancelled.PendingOperations.Count -ne 1){throw 'Interrupted staged scope lost its pending intent.'}
        $op=$cancelled.PendingOperations[0];if(@(Get-ChildItem -LiteralPath $op.Staging -Recurse -Filter *.partial -ErrorAction SilentlyContinue).Count){throw 'Cancelled payload left an unowned partial file.'}
        if($phase -ceq 'AfterFileScopePrepared' -and $op.Phase -cne 'Prepared'){throw 'Cancellation was not after the durable prepared boundary.'}
        Select-CancelBoundary ''
        Repair-WsmOperation $package.ManifestPath $package.SHA256 $targetState | Out-Null
        if(-not (Test-WsmJournal $targetState $pair).Consistent){throw 'Cancellation repair corrupted journal ownership.'}
    }
}
# The final prepared scope is adopted only through explicit repair; then a new token may verify/complete restore.
Select-CancelBoundary ''
$freshToken=New-WsmCancellationToken $pair $approval.SHA256 $package.SHA256 ([Guid]::NewGuid().ToString()) $targetState
$restored=Invoke-WsmRestore $package.ManifestPath $package.SHA256 $targetState -CancellationToken $freshToken
if($restored.Stage -cne 'Succeeded' -or (Get-FileHash -LiteralPath (Join-Path $targetRoot 'chunked.bin')).Hash -ine (Get-FileHash -LiteralPath (Join-Path $sourceRoot 'chunked.bin')).Hash){throw 'New operation could not safely complete after reviewed cancellation repair.'}
# Exercise the actual process exit contract using the immutable installed tool and trusted requests.
$engine=Join-Path $PSHOME 'powershell.exe';if(-not [IO.File]::Exists($engine)){$engine=Join-Path $PSHOME 'pwsh.exe'}
$entry=Join-Path $PSScriptRoot '..\Start-ServerMigration.ps1'
function Assert-WorkflowCli($Action,$Arguments,[int]$ExpectedCode,[string]$Name) {
    $request=[pscustomobject]@{SchemaVersion=1;ToolVersion='0.3.0';Kind='OperationRequest';Action=$Action;Arguments=$Arguments}
    $path=Join-Path $root ('cli-'+$Name+'.json');[IO.File]::WriteAllText($path,($request | ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
    $oldPreference=$ErrorActionPreference
    try{$ErrorActionPreference='Continue';& $engine -NoProfile -NonInteractive -File $entry -Action Operation -Path $path -ExpectedHash (Get-FileHash -LiteralPath $path).Hash *> (Join-Path $root ('cli-'+$Name+'.log'));$actual=$LASTEXITCODE}finally{$ErrorActionPreference=$oldPreference}
    if($actual -ne $ExpectedCode){throw ('Actual CLI '+$Name+' returned '+$actual+'; expected '+$ExpectedCode)}
}
Assert-WorkflowCli CheckPackage @{ManifestPath=$package.ManifestPath;ExpectedHash=$package.SHA256} 0 'verified'
Request-WsmCancellation $freshToken 'Fixture owner' 'actual CLI cancellation after successful fixture restore' | Out-Null
Assert-WorkflowCli CheckPackage @{ManifestPath=$package.ManifestPath;ExpectedHash=$package.SHA256;CancellationToken=$freshToken} 3 'cancelled'
$corruptRoot=Join-Path $root 'corrupt';Copy-Item -LiteralPath $package.Directory -Destination $corruptRoot -Recurse
$corruptBlob=Get-ChildItem -LiteralPath (Join-Path $corruptRoot 'payload') -Filter *.blob | Select-Object -First 1
$corruptBytes=[IO.File]::ReadAllBytes($corruptBlob.FullName);$corruptBytes[0]=$corruptBytes[0] -bxor 1;[IO.File]::WriteAllBytes($corruptBlob.FullName,$corruptBytes)
Assert-WorkflowCli CheckPackage @{ManifestPath=(Join-Path $corruptRoot 'manifest.json');ExpectedHash=$package.SHA256} 1 'corrupt-payload'
Assert-WorkflowCli UnknownAction @{} 4 'invalid-request'
$global:LASTEXITCODE=0
Write-Host ('PASS: trusted plan/source export/restore cancellation at sealed chunk, durable start/item/prepared boundaries; unsealed export preserved; partial files cleaned; live target untouched until explicit repair; new operation completed with exact bytes. Real files/journals, fixture host identity. Root: '+$root)
