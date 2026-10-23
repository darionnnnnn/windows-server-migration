#requires -Version 5.1
# P2: a retry of the same backup attempt reopens the same generation directory. The partial artifact index that the failed run left behind
# (artifacts.jsonl.partial) is the only record of the blobs it wrote, so it is moved aside as artifacts.jsonl.attempt-<AttemptId>-<NN>.partial
# (never copied, never overwritten) before a new partial index is opened. Real caller (Invoke-WsmWizardStartBackup), real capture, seal, verify and
# delivery. Only host qualification observations and the injected crash are substituted.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$driveLetter=(@('R','S','T','U','V','W','X','Y','Z') | Where-Object { -not (Test-Path -LiteralPath ($_+':\')) } | Select-Object -First 1)
if(-not $driveLetter){throw 'No free temporary drive letter is available for the short-path test.'}
$substCommand='subst '+$driveLetter+': "'+$tempBase.TrimEnd('\')+'"';cmd.exe /c $substCommand
if($LASTEXITCODE -ne 0){throw 'Unable to create a temporary drive alias for the test.'}
$root=Join-Path ($driveLetter+':\') ('wsmp2-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root)
        $script:Checks=0
        function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw ('FAIL: '+$Message)};$script:Checks++}
        function Sha([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
        function Try-Run([scriptblock]$Action){try{& $Action|Out-Null;$null}catch{$_.Exception}}
        function Bytes-Equal([byte[]]$A,[byte[]]$B){$A.Length -eq $B.Length -and ([BitConverter]::ToString($A) -ceq [BitConverter]::ToString($B))}
        $script:Fp=('a'*64)
        function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:Fp;Name='p2-fixture-source';OS='Fixture Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function script:Get-WsmPreflight {[pscustomobject]@{OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true;PowerShellVersion='5.1';ExecutionPolicy='AllSigned';LanguageMode='FullLanguage'}}
        $script:InventoryPath=''
        function script:Export-WsmInventory {param([string]$OutputDirectory,[switch]$DeepDiscovery);if(-not $script:InventoryPath){throw 'Fixture inventory observation was not initialized.'};[pscustomobject]@{Path=$script:InventoryPath;SHA256=(Get-FileHash -LiteralPath $script:InventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()}}
        $sourceRoot=Join-Path $Root 'source-work';$targetRoot=Join-Path $Root 'target-work'
        [void](Initialize-WsmOutputWorkspace $sourceRoot Source)
        $script:Fp=('b'*64);$targetEnrollment=Initialize-WsmOutputWorkspace $targetRoot Target
        $targetIdentityPath=Join-Path (Join-Path $targetRoot ('targets\'+$targetEnrollment.HostId)) 'target-identity.json';$targetIdentityHash=Sha $targetIdentityPath
        $script:Fp=('a'*64)
        $sourceEnrollment=Read-WsmOutputProfile $sourceRoot
        $source=[pscustomobject]@{HostId=$sourceEnrollment.HostId;Fingerprint=('a'*64);Name='fixture-source'}
        $dataA=Join-Path $Root 'data-a';$dataB=Join-Path $Root 'data-b';foreach($dir in @($dataA,$dataB)){[void][IO.Directory]::CreateDirectory($dir)}
        $fileA1=Join-Path $dataA 'a1.txt';$fileB1=Join-Path $dataB 'b1.txt';$fileB2=Join-Path $dataB 'b2.txt'
        function Set-SourceBytes([string]$Tag){[IO.File]::WriteAllText($fileA1,('scope A bytes '+$Tag));[IO.File]::WriteAllText($fileB1,('scope B first bytes '+$Tag));[IO.File]::WriteAllText($fileB2,('scope B second bytes '+$Tag))}
        Set-SourceBytes 'start'
        $itemA=New-WsmItem $source.HostId Storage DataRoot 'P2 scope A' 'p2-scope-a' @{Path=$dataA}
        $itemB=New-WsmItem $source.HostId Storage DataRoot 'P2 scope B' 'p2-scope-b' @{Path=$dataB}
        $inventory=New-WsmInventory $source 1 @($itemA,$itemB);$inventoryPath=Join-Path $Root 'inventory.json';Write-WsmJson $inventoryPath $inventory;$script:InventoryPath=$inventoryPath
        function New-P2Plan([string]$Label){
            $managerRoot=Join-Path $Root ('manager-'+$Label);Initialize-WsmWorkspace $managerRoot|Out-Null
            $catalog=Import-WsmInventory $managerRoot $inventoryPath (Sha $inventoryPath) ('target-'+$Label)
            foreach($pair in @(@($itemA,$dataA,'a'),@($itemB,$dataB,'b'))){
                $spec=[pscustomobject]@{Adapter='FileScope';SourcePath=$pair[1];TargetPath=(Join-Path $Root ('restored-'+$Label+'-'+$pair[2]));TransferChannel='C';ContentSelection='WholeScope';ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='AllowAutoInheritedUpgrade';ConflictPolicy='ReplaceOwned';Owner='Fixture owner';Evidence='P2 fixture';BusinessChecks=@('Read back each source file')}
                $specPath=Join-Path $Root ('spec-'+$Label+'-'+$pair[2]+'.json');Write-WsmJson $specPath $spec
                $revision=[int](Get-WsmCatalog $managerRoot $catalog.PairId).DecisionRevision
                Set-WsmMigrationSpec $managerRoot $catalog.PairId $pair[0].ItemId $specPath (Sha $specPath) $revision|Out-Null
            }
            $revision=[int](Get-WsmCatalog $managerRoot $catalog.PairId).DecisionRevision
            Set-WsmDecision $managerRoot $catalog.PairId @($itemA.ItemId,$itemB.ItemId) Include 'Explicit P2 selection' $revision|Out-Null
            $revision=[int](Get-WsmCatalog $managerRoot $catalog.PairId).DecisionRevision
            $planPath=Join-Path $Root ('approved-plan-'+$Label+'.json')
            $approved=Approve-WsmMigrationPlan $managerRoot $catalog.PairId $targetIdentityPath $targetIdentityHash $planPath $revision 'ISOLATED-PILOT'
            $script:Fp=('a'*64)
            $import=Import-WsmWizardApprovedPlan $sourceRoot Source $planPath $approved.SHA256
            if($import.Status -cne 'ImportedVerified'){throw ('Source did not import the approved '+$Label+' plan.')}
            [pscustomobject]@{PairId=[string]$catalog.PairId;PlanHash=[string]$approved.SHA256;PlanPath=$planPath}
        }
        function Start-Backup($PlanInfo,[string]$Op,[string]$Mode='Directory',[long]$Volume=0){
            $token=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $PlanInfo.PairId -PlanHash $PlanInfo.PlanHash -OperationId $Op
            Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $PlanInfo.PairId -OperationId $Op -Jobs @() -CancellationToken $token -DeliveryMode $Mode -VolumeBytes $Volume
        }
        function Get-Attempt($PlanInfo,[string]$Op){(Get-WsmWizardBackupAttemptForOperation $sourceRoot $PlanInfo.PairId (Read-WsmOutputProfile $sourceRoot) $Op).Attempt}
        $script:OrigPayload=(Get-Command Write-WsmPayloadFile -CommandType Function).ScriptBlock
        $script:OrigExport=(Get-Command Export-WsmMigrationPackage -CommandType Function).ScriptBlock
        $script:CrashDir=$dataB
        $script:CrashStub={param($SourcePath,$BlobRoot,$ChunkBytes,$BytesPerSecond,$CancellationToken=$null);if(([string]$SourcePath).StartsWith($script:CrashDir,[StringComparison]::OrdinalIgnoreCase)){throw 'Injected crash while the second scope is being captured.'};& $script:OrigPayload $SourcePath $BlobRoot $ChunkBytes $BytesPerSecond $CancellationToken}
        $script:SeenAttemptIds=New-Object Collections.ArrayList
        # Records the AttemptId the caller hands to the exporter; -StripAttemptId drops it so the exporter sees a call without one.
        function Install-ExportSpy([bool]$Strip){
            $script:StripAttempt=$Strip
            $spy={
                param([string]$PlanPath,[string]$ExpectedHash,[string]$SourceStateDirectory,[string]$OutputDirectory,[int]$ChunkBytes=67108864,[int]$BytesPerSecond=0,[string]$BaseManifestPath,[string]$BaseManifestHash,[string]$FreezePath,[string]$FreezeHash,[string]$FreezeExternalEvidencePath,[string]$FreezeExternalEvidenceHash,$CancellationToken=$null,[string]$MaterialWorkspace='',[string]$AttemptId='')
                [void]$script:SeenAttemptIds.Add($(if($PSBoundParameters.ContainsKey('AttemptId')){[string]$PSBoundParameters['AttemptId']}else{'<none>'}))
                $forward=@{};foreach($key in @($PSBoundParameters.Keys)){if(-not ($script:StripAttempt -and $key -ceq 'AttemptId')){$forward[$key]=$PSBoundParameters[$key]}}
                & $script:OrigExport @forward
            }
            Set-Item -Path Function:\script:Export-WsmMigrationPackage -Value $spy
        }
        function Remove-ExportSpy{Set-Item -Path Function:\script:Export-WsmMigrationPackage -Value $script:OrigExport}
        function Crash-Run($PlanInfo,[string]$Tag,[bool]$StripAttempt=$false,[string]$Mode='Directory',[long]$Volume=0){
            Set-SourceBytes $Tag
            $op=[Guid]::NewGuid().ToString('D')
            Set-Item -Path Function:\script:Write-WsmPayloadFile -Value $script:CrashStub
            Install-ExportSpy $StripAttempt
            try{$err=Try-Run {Start-Backup $PlanInfo $op $Mode $Volume}}finally{Set-Item -Path Function:\script:Write-WsmPayloadFile -Value $script:OrigPayload;Remove-ExportSpy}
            Check ($err -and $err.Message -like '*Injected crash*') ('the injected crash did not stop the run ('+$Tag+'): '+$err)
            $attempt=Get-Attempt $PlanInfo $op
            Check ($attempt.Stage -ceq 'Failed' -and -not $attempt.CoreExport) ('the crashed run was not recorded as a failed, unsealed attempt ('+$Tag+')')
            [pscustomobject]@{Op=$op;Attempt=$attempt;Packages=(Join-Path ([string]$attempt.OutputRoot) 'packages')}
        }
        function Get-GenerationRoot([string]$Packages){$dirs=@(Get-ChildItem -LiteralPath $Packages -Directory);Check ($dirs.Count -eq 1) 'exactly one generation directory is expected';$dirs[0].FullName}
        function Get-Partial([string]$Generation){$p=Join-Path $Generation 'artifacts.jsonl.partial';Check ([IO.File]::Exists($p)) 'the failed run left no partial index';$p}
        function Final-Retry($PlanInfo,[string]$Tag,[string]$Mode='Directory',[long]$Volume=0){
            Set-SourceBytes $Tag
            $op=[Guid]::NewGuid().ToString('D')
            Install-ExportSpy $false
            try{$result=Start-Backup $PlanInfo $op $Mode $Volume}finally{Remove-ExportSpy}
            Check ($result.Status -ceq 'Delivered') ('the retry did not deliver ('+$Tag+')')
            $attempt=Get-Attempt $PlanInfo $op
            [pscustomobject]@{Result=$result;Attempt=$attempt;Op=$op}
        }
        function Assert-SealedAndClean($PlanInfo,$Final,[string]$Mode){
            $package=Test-WsmMigrationPackage ([string]$Final.Attempt.CoreExport.ManifestPath) ([string]$Final.Attempt.CoreExport.SHA256)
            $rows=@(Read-WsmArtifactLines (Join-Path $package.Root 'artifacts.jsonl') $package.Manifest.ArtifactsHash|Where-Object {-not $_.Directory})
            $expected=@(Sha $fileA1;Sha $fileB1;Sha $fileB2)|Sort-Object
            Check ((@($rows|ForEach-Object {[string]$_.Data.Hash}|Sort-Object) -join ',') -ceq (@($expected) -join ',')) ($Mode+': the new artifacts.jsonl does not consist exactly of the retried bytes')
            Check ((Sha (Join-Path $package.Root 'artifacts.jsonl')) -ceq $package.Manifest.ArtifactsHash) ($Mode+': the sealed index hash differs from the manifest')
            Check (@(Get-ChildItem -LiteralPath $package.Root -File -Filter 'artifacts.jsonl.partial').Count -eq 0) ($Mode+': a stale artifacts.jsonl.partial remained after the seal')
            if($Mode -ceq 'Directory'){
                $delivered=[string]$Final.Result.Delivery.Directory
                $names=@(Get-ChildItem -LiteralPath $delivered -Recurse -File -Force|ForEach-Object {$_.Name})
                Check ($names.Count -ge 5) 'Directory: the delivery directory looks empty'
                Check (@($names|Where-Object {$_ -like '*attempt-*' -or $_ -like '*.partial'}).Count -eq 0) ('Directory: the delivery contains a preserved partial index: '+($names -join ','))
            }else{
                $script:Fp=('b'*64)
                try{$imported=Import-WsmPackageZip -TransportPath $Final.Result.Delivery.Path -ExpectedHash $Final.Result.Delivery.SHA256 -OutputDirectory (Join-Path $Root ('zip-imported-'+[Guid]::NewGuid().ToString('N').Substring(0,6)))}finally{$script:Fp=('a'*64)}
                $names=@(Get-ChildItem -LiteralPath (Split-Path -Parent $imported.ManifestPath) -Recurse -File -Force|ForEach-Object {$_.Name})
                Check ($names.Count -ge 5) 'Zip: the imported package looks empty'
                Check (@($names|Where-Object {$_ -like '*attempt-*' -or $_ -like '*.partial'}).Count -eq 0) ('Zip: the delivered package contains a preserved partial index: '+($names -join ','))
            }
            $package
        }

        try {
            # ===== 1. One failure then success (Directory delivery) =====
            $plan1=New-P2Plan 'one'
            $crash1=Crash-Run $plan1 'one-crash'
            $gen1=Get-GenerationRoot $crash1.Packages
            $partial1=Get-Partial $gen1
            $bytesAtFailure=[IO.File]::ReadAllBytes($partial1)
            Check ($bytesAtFailure.Length -gt 0) 'the partial index written before the failure is empty, so the test would prove nothing'
            $attemptId1=[string]$crash1.Attempt.AttemptId
            $final1=Final-Retry $plan1 'one-retry'
            Check ([string]$final1.Attempt.AttemptId -ceq $attemptId1) 'the retry did not continue the same attempt'
            $preserved1=Join-Path $gen1 ('artifacts.jsonl.attempt-'+$attemptId1+'-01.partial')
            Check ([IO.File]::Exists($preserved1)) ('the previous partial index was not preserved as '+[IO.Path]::GetFileName($preserved1))
            Check (Bytes-Equal ([IO.File]::ReadAllBytes($preserved1)) $bytesAtFailure) 'the preserved index differs from the bytes the failed run left'
            Check (@(Get-ChildItem -LiteralPath $gen1 -File -Filter 'artifacts.jsonl.attempt-*').Count -eq 1) 'more than one preserved index appeared after a single failure'
            [void](Assert-SealedAndClean $plan1 $final1 'Directory')
            Write-Host 'PASS: P2-1 one failure then success: old index preserved byte for byte, new index sealed, Directory delivery excludes it.'

            # ===== 1b. The caller hands its attempt id to the exporter =====
            Install-ExportSpy $false
            try{
                $plan1b=New-P2Plan 'spy'
                $opSpy=[Guid]::NewGuid().ToString('D');$script:SeenAttemptIds.Clear()
                $spyResult=Start-Backup $plan1b $opSpy
            }finally{Remove-ExportSpy}
            Check ($spyResult.Status -ceq 'Delivered' -and $script:SeenAttemptIds.Count -eq 1 -and [string]$script:SeenAttemptIds[0] -ceq [string]$spyResult.AttemptId) ('the one-click backup did not pass its AttemptId to the exporter (saw: '+($script:SeenAttemptIds -join ',')+')')
            Write-Host 'PASS: P2-1b the one-click backup passes its attempt id to the exporter.'

            # ===== 2. ZIP delivery =====
            $planZ=New-P2Plan 'zip'
            $crashZ=Crash-Run $planZ 'zip-crash' $false 'Zip' 134217728
            $genZ=Get-GenerationRoot $crashZ.Packages
            $bytesZ=[IO.File]::ReadAllBytes((Get-Partial $genZ))
            $finalZ=Final-Retry $planZ 'zip-retry' 'Zip' 134217728
            $preservedZ=Join-Path $genZ ('artifacts.jsonl.attempt-'+[string]$crashZ.Attempt.AttemptId+'-01.partial')
            Check ([IO.File]::Exists($preservedZ) -and (Bytes-Equal ([IO.File]::ReadAllBytes($preservedZ)) $bytesZ)) 'Zip: the old index was not preserved byte for byte'
            [void](Assert-SealedAndClean $planZ $finalZ 'Zip')
            Write-Host 'PASS: P2-2 ZIP delivery after a retry does not carry the preserved index.'

            # ===== 3. Two failures then success: -01 and -02, never overwritten =====
            $plan3=New-P2Plan 'two'
            $crashA=Crash-Run $plan3 'two-crash-1'
            $gen3=Get-GenerationRoot $crashA.Packages
            $bytes3a=[IO.File]::ReadAllBytes((Get-Partial $gen3))
            $crashB=Crash-Run $plan3 'two-crash-2'
            Check ([string]$crashB.Attempt.AttemptId -ceq [string]$crashA.Attempt.AttemptId) 'the second crash was not a retry of the same attempt'
            $id3=[string]$crashA.Attempt.AttemptId
            $first3=Join-Path $gen3 ('artifacts.jsonl.attempt-'+$id3+'-01.partial')
            Check ([IO.File]::Exists($first3) -and (Bytes-Equal ([IO.File]::ReadAllBytes($first3)) $bytes3a)) 'after the second failure the first partial index is not kept as -01'
            $bytes3b=[IO.File]::ReadAllBytes((Get-Partial $gen3))
            Check (-not (Bytes-Equal $bytes3a $bytes3b)) 'the two failed runs left identical partial indexes, so overwrite could not be told apart'
            $final3=Final-Retry $plan3 'two-retry'
            $second3=Join-Path $gen3 ('artifacts.jsonl.attempt-'+$id3+'-02.partial')
            Check ([IO.File]::Exists($first3) -and (Bytes-Equal ([IO.File]::ReadAllBytes($first3)) $bytes3a)) 'the -01 file was changed by the third run'
            Check ([IO.File]::Exists($second3) -and (Bytes-Equal ([IO.File]::ReadAllBytes($second3)) $bytes3b)) 'the second partial index is not kept as -02'
            Check (@(Get-ChildItem -LiteralPath $gen3 -File -Filter 'artifacts.jsonl.attempt-*').Count -eq 2) 'unexpected number of preserved indexes after two failures'
            [void](Assert-SealedAndClean $plan3 $final3 'Directory')
            Write-Host 'PASS: P2-3 two failures then success: -01 and -02, byte-exact, nothing overwritten.'

            # ===== 4. A same-name preserved file already exists: never overwritten, next number is used =====
            $dir4=Join-Path $Root 'unit-existing';[void][IO.Directory]::CreateDirectory($dir4)
            $sentinel=[Text.Encoding]::UTF8.GetBytes('sentinel that must survive')
            [IO.File]::WriteAllBytes((Join-Path $dir4 'artifacts.jsonl.attempt-ATT-1-01.partial'),$sentinel)
            $new4=[Text.Encoding]::UTF8.GetBytes('{"partial":"to be moved"}')
            [IO.File]::WriteAllBytes((Join-Path $dir4 'artifacts.jsonl.partial'),$new4)
            $moved4=Save-WsmPartialArtifactIndex $dir4 'ATT-1'
            Check ([IO.Path]::GetFileName($moved4) -ceq 'artifacts.jsonl.attempt-ATT-1-02.partial') ('the next free number was not used: '+$moved4)
            Check (Bytes-Equal ([IO.File]::ReadAllBytes((Join-Path $dir4 'artifacts.jsonl.attempt-ATT-1-01.partial'))) $sentinel) 'the pre-existing same-name file was overwritten'
            Check ((Bytes-Equal ([IO.File]::ReadAllBytes($moved4)) $new4) -and -not [IO.File]::Exists((Join-Path $dir4 'artifacts.jsonl.partial'))) 'the partial index was not moved intact'
            Check ($null -eq (Save-WsmPartialArtifactIndex $dir4 'ATT-1')) 'with no partial index present nothing must be moved'
            # More than 99 preserved files is refused and the partial index stays where it is.
            $dir4b=Join-Path $Root 'unit-full';[void][IO.Directory]::CreateDirectory($dir4b)
            1..99|ForEach-Object {[IO.File]::WriteAllBytes((Join-Path $dir4b ('artifacts.jsonl.attempt-FULL-'+$_.ToString('00')+'.partial')),$sentinel)}
            [IO.File]::WriteAllBytes((Join-Path $dir4b 'artifacts.jsonl.partial'),$new4)
            $fullError=Try-Run {Save-WsmPartialArtifactIndex $dir4b 'FULL'}
            Check ($fullError -and $fullError.Message -like '*limit 99*') 'the 100th preserved index was not refused'
            Check ((Bytes-Equal ([IO.File]::ReadAllBytes((Join-Path $dir4b 'artifacts.jsonl.partial'))) $new4) -and @(Get-ChildItem -LiteralPath $dir4b -File).Count -eq 100) 'a refused preservation changed the directory'
            Write-Host 'PASS: P2-4 a pre-existing same-name file is never overwritten; the next number is used; 99 is the limit.'

            # ===== 5. No AttemptId given: the name uses "unknown" and the index is still set aside =====
            $plan5=New-P2Plan 'unknown'
            $crash5=Crash-Run $plan5 'unknown-crash' $true
            $gen5=Get-GenerationRoot $crash5.Packages
            $bytes5=[IO.File]::ReadAllBytes((Get-Partial $gen5))
            [void](Crash-Run $plan5 'unknown-crash-2' $true)
            $unknown1=Join-Path $gen5 'artifacts.jsonl.attempt-unknown-01.partial'
            Check ([IO.File]::Exists($unknown1) -and (Bytes-Equal ([IO.File]::ReadAllBytes($unknown1)) $bytes5)) 'without AttemptId the old index was not set aside as attempt-unknown-01'
            Check ((Save-WsmPartialArtifactIndex $dir4 '') -eq $null) 'unit: nothing to move'
            [IO.File]::WriteAllBytes((Join-Path $dir4 'artifacts.jsonl.partial'),$new4)
            Check ([IO.Path]::GetFileName((Save-WsmPartialArtifactIndex $dir4 '')) -ceq 'artifacts.jsonl.attempt-unknown-01.partial') 'an empty AttemptId is not named unknown'
            Write-Host 'PASS: P2-5 no AttemptId: attempt-unknown-NN, still set aside and not overwritten.'

            # ===== 6. Hostile attempt ids are made safe =====
            $dir6=Join-Path $Root 'unit-safe';[void][IO.Directory]::CreateDirectory($dir6)
            foreach($case in @(
                @('..\evil/../x','artifacts.jsonl.attempt-evilx-01.partial'),
                @('..\','artifacts.jsonl.attempt-unknown-01.partial'),
                @('a:b*c?d"e<f>g|h i','artifacts.jsonl.attempt-abcdefghi-01.partial'),
                @(('z'*100),('artifacts.jsonl.attempt-'+('z'*64)+'-01.partial'))
            )){
                [IO.File]::WriteAllBytes((Join-Path $dir6 'artifacts.jsonl.partial'),$new4)
                $saved=Save-WsmPartialArtifactIndex $dir6 ([string]$case[0])
                Check ([IO.Path]::GetFileName($saved) -ceq $case[1] -and [IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($saved)) -ieq [IO.Path]::GetFullPath($dir6)) ('attempt id '+$case[0]+' was not made safe: '+$saved)
                Remove-Item -LiteralPath $saved -Force
            }
            Check (-not [IO.Directory]::Exists((Join-Path $Root 'evil')) -and @(Get-ChildItem -LiteralPath $dir6 -Force).Count -eq 0) 'a hostile attempt id escaped the generation directory'
            Write-Host 'PASS: P2-6 attempt ids are reduced to [A-Za-z0-9-], at most 64 characters.'
        } finally {
            Set-Item -Path Function:\script:Write-WsmPayloadFile -Value $script:OrigPayload
            Set-Item -Path Function:\script:Export-WsmMigrationPackage -Value $script:OrigExport
        }
        Write-Host ('PASS: P2 retry partial index preserved ('+$script:Checks+' checks).')
    } $root
} finally {
    $full=[IO.Path]::GetFullPath($root);$driveRoot=[IO.Path]::GetPathRoot($full)
    if($full -ieq $driveRoot -or [IO.Path]::GetDirectoryName($full) -ine $driveRoot -or [IO.Path]::GetFileName($full) -notlike 'wsmp2-*'){throw 'Unsafe cleanup path.'}
    if([IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
    cmd.exe /c ('subst '+$driveLetter+': /D')
}
