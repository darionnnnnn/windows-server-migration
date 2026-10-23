#requires -Version 5.1
# N4 reliability scenarios 16.6-1 / 16.6-2 / 16.6-3 for the one-click backup core (Invoke-WsmWizardStartBackup).
# Real caller, real capture / seal / verify / delivery code. Only host qualification observations and the injected
# faults (a crash seam, a counting wrapper) are substituted. The HTTP route layer of 16.6-1 is Test-StartBackupReplayHttp.js.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$evidenceFixturePath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'ExternalReadinessEvidenceFixtures.ps1'))
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$driveLetter=(@('R','S','T','U','V','W','X','Y','Z') | Where-Object { -not (Test-Path -LiteralPath ($_+':\')) } | Select-Object -First 1)
if(-not $driveLetter){throw 'No free temporary drive letter is available for the short-path reliability test.'}
$substCommand='subst '+$driveLetter+': "'+$tempBase.TrimEnd('\')+'"';cmd.exe /c $substCommand
if($LASTEXITCODE -ne 0){throw 'Unable to create a temporary drive alias for the reliability test.'}
$root=Join-Path ($driveLetter+':\') ('wsmrl-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root,$EvidenceFixturePath)
        . $EvidenceFixturePath
        $script:rlChecks=0
        function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:rlChecks++}
        function Sha([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
        function Try-Run([scriptblock]$Action){try{& $Action|Out-Null;$null}catch{$_.Exception}}
        function Tree([string]$Directory){(@(Get-ChildItem -LiteralPath $Directory -Recurse -File -Force|Sort-Object FullName|ForEach-Object {$_.FullName+'|'+(Sha $_.FullName)}) -join "`n")}
        $script:rlFp=('a'*64)
        function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:rlFp;Name='reliability-fixture-source';OS='Fixture Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function script:Get-WsmPreflight {[pscustomobject]@{OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true;PowerShellVersion='5.1';ExecutionPolicy='AllSigned';LanguageMode='FullLanguage'}}
        $script:rlInventoryPath=''
        function script:Export-WsmInventory {param([string]$OutputDirectory,[switch]$DeepDiscovery);if(-not $script:rlInventoryPath){throw 'Fixture inventory observation was not initialized.'};[pscustomobject]@{Path=$script:rlInventoryPath;SHA256=(Get-FileHash -LiteralPath $script:rlInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()}}
        $sourceRoot=Join-Path $Root 'source-work';$targetRoot=Join-Path $Root 'target-work';$managerRoot=Join-Path $Root 'manager-work'
        $sourceEnrollment=Initialize-WsmOutputWorkspace $sourceRoot Source
        $script:rlFp=('b'*64);$targetEnrollment=Initialize-WsmOutputWorkspace $targetRoot Target
        $targetIdentityPath=Join-Path (Join-Path $targetRoot ('targets\'+$targetEnrollment.HostId)) 'target-identity.json';$targetIdentityHash=Sha $targetIdentityPath
        $script:rlFp=('a'*64)
        $source=[pscustomobject]@{HostId=$sourceEnrollment.HostId;Fingerprint=('a'*64);Name='fixture-source'}
        # Two reviewed scopes in one plan: scope A is the channel captured first (C), scope B the one captured after it. Scenario 2 labels
        # both C (an Immutable plan needs no freeze); scenario 2b labels B NonC, the label the current flow uses for the second channel.
        # This machine has no extra drive-lettered volume, so a physically separate NonC volume cannot be captured natively.
        $dataA=Join-Path $Root 'data-a';$dataB=Join-Path $Root 'data-b';foreach($dir in @($dataA,$dataB)){[void][IO.Directory]::CreateDirectory($dir)}
        $fileA1=Join-Path $dataA 'a1.txt';$fileB1=Join-Path $dataB 'b1.txt';$fileB2=Join-Path $dataB 'b2.txt'
        function Set-SourceBytes([string]$Tag){[IO.File]::WriteAllText($fileA1,('scope A bytes '+$Tag));[IO.File]::WriteAllText($fileB1,('scope B first bytes '+$Tag));[IO.File]::WriteAllText($fileB2,('scope B second bytes '+$Tag))}
        Set-SourceBytes 'generation-one'
        $itemA=New-WsmItem $source.HostId Storage DataRoot 'Reliability scope A' 'reliability-scope-a' @{Path=$dataA}
        $itemB=New-WsmItem $source.HostId Storage DataRoot 'Reliability scope B' 'reliability-scope-b' @{Path=$dataB}
        $inventory=New-WsmInventory $source 1 @($itemA,$itemB);$inventoryPath=Join-Path $Root 'inventory.json';Write-WsmJson $inventoryPath $inventory;$script:rlInventoryPath=$inventoryPath
        function New-ReliabilityPlan([string]$Label,[string]$Consistency,[string]$SecondChannel='C'){
            $managerRoot=Join-Path $Root ('manager-'+$Label);Initialize-WsmWorkspace $managerRoot|Out-Null
            $catalog=Import-WsmInventory $managerRoot $inventoryPath (Sha $inventoryPath) ('target-'+$Label)
            foreach($pair in @(@($itemA,$dataA,'a','C'),@($itemB,$dataB,'b',$SecondChannel))){
                $spec=[pscustomobject]@{Adapter='FileScope';SourcePath=$pair[1];TargetPath=(Join-Path $Root ('restored-'+$Label+'-'+$pair[2]));TransferChannel=$pair[3];ContentSelection='WholeScope';ExcludedRelativePaths=@();Consistency=$Consistency;Metadata='DaclOwner';AclControlPolicy='AllowAutoInheritedUpgrade';ConflictPolicy='ReplaceOwned';Owner='Fixture owner';Evidence='Reliability fixture';BusinessChecks=@('Read back each source file')}
                $specPath=Join-Path $Root ('spec-'+$Label+'-'+$pair[2]+'.json');Write-WsmJson $specPath $spec
                $revision=[int](Get-WsmCatalog $managerRoot $catalog.PairId).DecisionRevision
                Set-WsmMigrationSpec $managerRoot $catalog.PairId $pair[0].ItemId $specPath (Sha $specPath) $revision|Out-Null
            }
            $revision=[int](Get-WsmCatalog $managerRoot $catalog.PairId).DecisionRevision
            Set-WsmDecision $managerRoot $catalog.PairId @($itemA.ItemId,$itemB.ItemId) Include 'Explicit reliability selection' $revision|Out-Null
            $revision=[int](Get-WsmCatalog $managerRoot $catalog.PairId).DecisionRevision
            $planPath=Join-Path $Root ('approved-plan-'+$Label+'.json')
            $approved=Approve-WsmMigrationPlan $managerRoot $catalog.PairId $targetIdentityPath $targetIdentityHash $planPath $revision 'ISOLATED-PILOT'
            $script:rlFp=('a'*64)
            $import=Import-WsmWizardApprovedPlan $sourceRoot Source $planPath $approved.SHA256
            if($import.Status -cne 'ImportedVerified'){throw ('Source did not import the approved '+$Label+' plan.')}
            [pscustomobject]@{PairId=[string]$catalog.PairId;PlanHash=[string]$approved.SHA256;PlanPath=$planPath;Plan=(Read-WsmMigrationPlan $planPath $approved.SHA256)}
        }
        function Start-Backup($PlanInfo,[string]$Op,[string]$Mode='Directory',[long]$Volume=0,$Freeze=$null){
            $token=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $PlanInfo.PairId -PlanHash $PlanInfo.PlanHash -OperationId $Op
            if($Freeze){return (Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $PlanInfo.PairId -OperationId $Op -Owner $Freeze.Owner -Evidence $Freeze.EvidenceText -FreezeAuthorization -FreezeExternalEvidencePath $Freeze.Proof.Path -FreezeExternalEvidenceHash $Freeze.Proof.SHA256 -Jobs @() -CancellationToken $token -DeliveryMode $Mode -VolumeBytes $Volume)}
            Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $PlanInfo.PairId -OperationId $Op -Jobs @() -CancellationToken $token -DeliveryMode $Mode -VolumeBytes $Volume
        }
        function Get-Attempt($PlanInfo,[string]$Op){(Get-WsmWizardBackupAttemptForOperation $sourceRoot $PlanInfo.PairId (Read-WsmOutputProfile $sourceRoot) $Op).Attempt}
        function Count-AttemptFiles($PlanInfo){@(Get-ChildItem -LiteralPath (Get-WsmWizardBackupRoot $sourceRoot $PlanInfo.PairId) -Filter '*.json' -File).Count}
        function Count-FreezeFolders($PlanInfo){$pairs=Join-Path $sourceRoot 'pairs';if(-not [IO.Directory]::Exists($pairs)){return 0};@(Get-ChildItem -LiteralPath $pairs -Directory -Filter ('freeze-'+$PlanInfo.PairId+'-*')).Count}
        function Find-Files([string]$Directory,[string[]]$Patterns){@(Get-ChildItem -LiteralPath $Directory -Recurse -Force -ErrorAction SilentlyContinue|Where-Object {$name=$_.Name;@($Patterns|Where-Object {$name -like $_}).Count -gt 0})}
        $script:rlOrig=@{};$script:rlCalls=@{}
        function Install-Counter([string]$Name){
            $script:rlOrig[$Name]=(Get-Command $Name -CommandType Function).ScriptBlock;$script:rlCalls[$Name]=0
            Set-Item -Path ('Function:\script:'+$Name) -Value ([scriptblock]::Create('$script:rlCalls['''+$Name+''']++; & $script:rlOrig['''+$Name+'''] @args'))
        }
        function Remove-Counter([string]$Name){if($script:rlOrig.ContainsKey($Name)){Set-Item -Path ('Function:\script:'+$Name) -Value $script:rlOrig[$Name];$script:rlOrig.Remove($Name)}}
        $freezeOwner='Fixture freeze owner';$freezeEvidenceText='Synthetic owner-confirmed quiescence; fixture only.'
        function New-FreezeAuthorization($PlanInfo){[pscustomobject]@{Owner=$freezeOwner;EvidenceText=$freezeEvidenceText;Proof=(New-WsmSourceFreezeEvidenceFixture -Plan $PlanInfo.Plan -PlanHash $PlanInfo.PlanHash -Root $Root -Owner $freezeOwner)}}
        $script:rlOrigPayload=(Get-Command Write-WsmPayloadFile -CommandType Function).ScriptBlock
        $script:rlOrigCopyMember=(Get-Command Copy-WsmOutputMember -CommandType Function).ScriptBlock
        $script:rlOrigStreamCopy=(Get-Command Copy-WsmCancellableStream -CommandType Function).ScriptBlock
        $script:rlOrigFreeze=(Get-Command Export-WsmFreezeRecord -CommandType Function).ScriptBlock
        $script:rlCounterNames=@('Export-WsmMigrationPackage','Export-WsmMigrationPackageCore','Write-WsmPayloadFile','Get-WsmScopeEntries','Get-WsmFileMetadata','Export-WsmFreezeRecord','Export-WsmInventory')
        try {
            # ================= 16.6-1: StartBackup 202 lost, the same operation id is sent again =================
            $freezePlan=New-ReliabilityPlan 'freeze' 'OwnerFreeze'
            $freezeAuth=New-FreezeAuthorization $freezePlan
            $opOne=[Guid]::NewGuid().ToString('D')
            $script:rlFreezeCalls=0;$script:rlMidReplay=$null;$script:rlMidReplayError=$null;$script:rlMidAttemptFiles=-1
            $script:rlReplayArgs=@{Plan=$freezePlan;Op=$opOne;Auth=$freezeAuth}
            function script:Export-WsmFreezeRecord {
                [CmdletBinding(SupportsShouldProcess)]param([string]$PlanPath,[string]$ExpectedHash,[string]$Path,[string]$Owner,[string]$Evidence,[Parameter(Mandatory)][string]$Acknowledgement,[switch]$SourceIdentityReleased,[string]$ReleaseEvidence,[ValidateRange(1,48)][int]$ValidHours=4,[Parameter(Mandatory)][string]$SourceStateDirectory,[string]$PreviousFreezePath,[string]$PreviousFreezeHash,[string]$PreviousAttemptPath,[string]$PreviousAttemptHash,[Parameter(Mandatory)][string]$FreezeExternalEvidencePath,[Parameter(Mandatory)][string]$FreezeExternalEvidenceHash,[string]$FreezeEpoch)
                $script:rlFreezeCalls++
                $freezeResult=& $script:rlOrigFreeze @PSBoundParameters
                # The source is frozen and durable now. The client never saw the 202, so it sends the very same operation again
                # while this worker is still running.
                try{$script:rlMidReplay=Start-Backup $script:rlReplayArgs.Plan $script:rlReplayArgs.Op 'Directory' 0 $script:rlReplayArgs.Auth}catch{$script:rlMidReplayError=$_.Exception}
                $script:rlMidAttemptFiles=Count-AttemptFiles $script:rlReplayArgs.Plan
                $freezeResult
            }
            try{$first=Start-Backup $freezePlan $opOne 'Directory' 0 $freezeAuth}finally{Set-Item -Path Function:\script:Export-WsmFreezeRecord -Value $script:rlOrigFreeze}
            Check ($first.Status -ceq 'Delivered' -and $first.Stage -ceq 'Delivered') 'Scenario 1: the first submission did not finish with the real freeze, capture, verify and delivery chain.'
            Check ($script:rlFreezeCalls -eq 1) ('Scenario 1: the source freeze ran '+$script:rlFreezeCalls+' times for one operation id.')
            Check ($null -eq $script:rlMidReplayError) ('Scenario 1: replaying the id while the first worker was running failed: '+$script:rlMidReplayError)
            Check ($script:rlMidReplay -and $script:rlMidReplay.AttemptId -ceq $first.AttemptId -and $script:rlMidReplay.Stage -ceq 'Authorized' -and -not $script:rlMidReplay.CoreExport) 'Scenario 1: the in-flight replay did not return the original, still running attempt.'
            Check ($script:rlMidAttemptFiles -eq 1) 'Scenario 1: the in-flight replay created a second backup operation record.'
            $attemptFileOne=Join-Path (Get-WsmWizardBackupRoot $sourceRoot $freezePlan.PairId) ($opOne+'.json')
            $hashAfterFirst=Sha $attemptFileOne
            $manifestOne=[string]$first.CoreExport.ManifestPath;$treeAfterFirst=Tree (Split-Path -Parent $manifestOne)
            Check ((Count-FreezeFolders $freezePlan) -eq 1) 'Scenario 1: the durable state does not show exactly one source freeze attempt after the first operation.'
            $script:rlFreezeCalls=0
            function script:Export-WsmFreezeRecord {
                [CmdletBinding(SupportsShouldProcess)]param([string]$PlanPath,[string]$ExpectedHash,[string]$Path,[string]$Owner,[string]$Evidence,[Parameter(Mandatory)][string]$Acknowledgement,[switch]$SourceIdentityReleased,[string]$ReleaseEvidence,[ValidateRange(1,48)][int]$ValidHours=4,[Parameter(Mandatory)][string]$SourceStateDirectory,[string]$PreviousFreezePath,[string]$PreviousFreezeHash,[string]$PreviousAttemptPath,[string]$PreviousAttemptHash,[Parameter(Mandatory)][string]$FreezeExternalEvidencePath,[Parameter(Mandatory)][string]$FreezeExternalEvidenceHash,[string]$FreezeEpoch)
                $script:rlFreezeCalls++
                & $script:rlOrigFreeze @PSBoundParameters
            }
            foreach($name in @('Export-WsmMigrationPackage','Write-WsmPayloadFile')){Install-Counter $name}
            try{
                $late=Start-Backup $freezePlan $opOne 'Directory' 0 $freezeAuth
                $lateNoEvidence=Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $freezePlan.PairId -OperationId $opOne -Jobs @()
                $exportCalls=$script:rlCalls['Export-WsmMigrationPackage'];$payloadCalls=$script:rlCalls['Write-WsmPayloadFile']
            }finally{foreach($name in @('Export-WsmMigrationPackage','Write-WsmPayloadFile')){Remove-Counter $name};Set-Item -Path Function:\script:Export-WsmFreezeRecord -Value $script:rlOrigFreeze}
            Check ($late.AttemptId -ceq $first.AttemptId -and $late.Status -ceq 'Delivered' -and $late.Delivery.SHA256 -ceq $first.Delivery.SHA256) 'Scenario 1: the late replay did not return the original delivered attempt.'
            Check ($lateNoEvidence.AttemptId -ceq $first.AttemptId -and $lateNoEvidence.Status -ceq 'Delivered') 'Scenario 1: a replay that carries no freeze authorization must still resolve to the original attempt by operation id.'
            Check ($script:rlFreezeCalls -eq 0 -and $exportCalls -eq 0 -and $payloadCalls -eq 0) ('Scenario 1: a replay froze again or captured again. freeze='+$script:rlFreezeCalls+' export='+$exportCalls+' payload='+$payloadCalls)
            Check ((Count-AttemptFiles $freezePlan) -eq 1 -and (Count-FreezeFolders $freezePlan) -eq 1) 'Scenario 1: replay created a second operation record or a second freeze attempt folder.'
            Check ((Sha $attemptFileOne) -ceq $hashAfterFirst -and (Tree (Split-Path -Parent $manifestOne)) -ceq $treeAfterFirst) 'Scenario 1: replay changed the durable attempt record or the sealed package.'
            $attemptOne=Get-Attempt $freezePlan $opOne
            Check (@($attemptOne.OperationIds).Count -eq 1 -and [int]$attemptOne.ResumeCount -eq 0) 'Scenario 1: replay was recorded as a new operation or a resume of the attempt.'
            # A different id for the same pair is a new request, not a replay. The finished attempt is not reopened by the old id.
            Write-Host 'PASS: 16.6-1 lost 202, same operation id replayed (in flight and after completion): one freeze, one attempt, original result.'

            # ================= 16.6-2: first channel captured, second channel interrupted, consistency lost =================
            $crashPlan=New-ReliabilityPlan 'crash' 'Immutable'
            $opCrash=[Guid]::NewGuid().ToString('D')
            $script:rlCrashDir=$dataB
            function script:Write-WsmPayloadFile {param($SourcePath,$BlobRoot,$ChunkBytes,$BytesPerSecond,$CancellationToken=$null);if(([string]$SourcePath).StartsWith($script:rlCrashDir,[StringComparison]::OrdinalIgnoreCase)){throw 'Injected crash while the second channel scope is being captured.'};& $script:rlOrigPayload $SourcePath $BlobRoot $ChunkBytes $BytesPerSecond $CancellationToken}
            try{$crashError=Try-Run {Start-Backup $crashPlan $opCrash}}finally{Set-Item -Path Function:\script:Write-WsmPayloadFile -Value $script:rlOrigPayload}
            $crashAttempt=Get-Attempt $crashPlan $opCrash
            Check ($crashError -and $crashError.Message -like '*Injected crash*' -and $crashAttempt.Stage -ceq 'Failed' -and $crashAttempt.ResumeStage -ceq 'Authorized' -and -not $crashAttempt.CoreExport) 'Scenario 2: the interrupted capture was not recorded as a failed, unsealed attempt.'
            $crashResult=ConvertTo-WsmWizardBackupResult $crashAttempt $opCrash
            Check ((Get-WsmOperationStatusCode $crashResult) -eq 1 -and $crashResult.Status -cne 'Delivered' -and -not $crashResult.Delivery) 'Scenario 2: the parent operation reports success although the second channel never finished.'
            $packagesDir=Join-Path ([string]$crashAttempt.OutputRoot) 'packages'
            Check (@(Find-Files $packagesDir @('manifest.json','manifest.pending.json')).Count -eq 0) 'Scenario 2: an interrupted capture left a sealed or pending manifest.'
            $partialFiles=@(Find-Files $packagesDir @('artifacts.jsonl.partial'));Check ($partialFiles.Count -eq 1) 'Scenario 2: the interrupted capture did not leave exactly one partial index for inspection.'
            $partialRows=@(Get-Content -LiteralPath $partialFiles[0].FullName -Encoding UTF8|Where-Object {$_}|ForEach-Object {$_|ConvertFrom-Json})
            $oldBlobHash=Sha $fileA1
            $partialA=@($partialRows|Where-Object {$_.ItemId -ceq $itemA.ItemId});$partialB=@($partialRows|Where-Object {$_.ItemId -ceq $itemB.ItemId})
            Check ($partialA.Count -eq 2 -and @($partialA|Where-Object {-not $_.Directory -and $_.RelativePath -ceq 'a1.txt' -and $_.Data.Hash -ceq $oldBlobHash}).Count -eq 1 -and @($partialB|Where-Object {-not $_.Directory}).Count -eq 0) 'Scenario 2: the kept partial does not hold the finished first channel (and no file of the unfinished second one).'
            $partialBytesBefore=[IO.File]::ReadAllBytes($partialFiles[0].FullName)
            $oldBlobPath=Join-Path (Join-Path (Split-Path -Parent $partialFiles[0].FullName) 'payload') ($oldBlobHash+'.blob')
            Check ([IO.File]::Exists($oldBlobPath)) 'Scenario 2: the first channel blob was not kept for inspection.'
            $generationDirs=@(Get-ChildItem -LiteralPath $packagesDir -Directory);Check ($generationDirs.Count -eq 1 -and $generationDirs[0].Name -like '*-g1') 'Scenario 2: unexpected generation folders after the interruption.'
            # Consistency is lost: the source changes after the crash. Both scopes change.
            Set-SourceBytes 'generation-two'
            $opRetry=[Guid]::NewGuid().ToString('D')
            $retried=Start-Backup $crashPlan $opRetry
            $retryAttempt=Get-Attempt $crashPlan $opRetry
            Check ($retried.Status -ceq 'Delivered' -and $retryAttempt.AttemptId -ceq $crashAttempt.AttemptId -and [int]$retryAttempt.ResumeCount -eq 1) 'Scenario 2: the retry did not finish the interrupted attempt.'
            $packageTwo=Test-WsmMigrationPackage ([string]$retryAttempt.CoreExport.ManifestPath) ([string]$retryAttempt.CoreExport.SHA256)
            $rowsTwo=@(Read-WsmArtifactLines (Join-Path $packageTwo.Root 'artifacts.jsonl') $packageTwo.Manifest.ArtifactsHash)
            $fileRows=@($rowsTwo|Where-Object {-not $_.Directory})
            $expectedHashes=@(Sha $fileA1;Sha $fileB1;Sha $fileB2)|Sort-Object
            $actualHashes=@($fileRows|ForEach-Object {[string]$_.Data.Hash}|Sort-Object)
            Check ((@($actualHashes) -join ',') -ceq (@($expectedHashes) -join ',')) 'Scenario 2: the sealed generation does not consist exactly of the new bytes of both channels.'
            Check (@($fileRows|Where-Object {$_.Data.Hash -ceq $oldBlobHash}).Count -eq 0 -and @($fileRows|ForEach-Object {$_.Data.Chunks}|Where-Object {$_.Hash -ceq $oldBlobHash}).Count -eq 0) 'Scenario 2: the old first-channel bytes were spliced into the new generation.'
            Check ($packageTwo.Manifest.Generation -eq 1 -and $packageTwo.Manifest.Files -eq 3 -and $packageTwo.Manifest.Records -eq $rowsTwo.Count -and (Sha ([string]$retryAttempt.CoreExport.ManifestPath)) -ieq [string]$retryAttempt.CoreExport.SHA256 -and (Sha (Join-Path $packageTwo.Root 'artifacts.jsonl')) -ceq $packageTwo.Manifest.ArtifactsHash) 'Scenario 2: manifest generation, counts or artifact hash do not match the sealed members.'
            $sizeSum=[long]0;foreach($file in @($fileA1,$fileB1,$fileB2)){$sizeSum+=(New-Object IO.FileInfo($file)).Length};Check ($packageTwo.Manifest.Bytes -eq $sizeSum) 'Scenario 2: sealed byte count does not equal the new source size.'
            $deliveredRoot=[string]$retried.Delivery.Directory;$summaryTwo=Read-WsmTrustedJson ([string]$retried.Delivery.Path) ([string]$retried.Delivery.SHA256)
            foreach($member in @($summaryTwo.Members)){if((Sha (Join-Path $deliveredRoot ([string]$member.Name).Replace('/','\'))) -cne ([string]$member.SHA256).ToLowerInvariant()){throw ('Scenario 2: delivered member differs from the sealed summary: '+$member.Name)}}
            $deliveredBlobs=@(Get-ChildItem -LiteralPath (Join-Path $deliveredRoot 'payload') -Filter '*.blob' -File|ForEach-Object {$_.BaseName}|Sort-Object)
            Check ((@($deliveredBlobs) -join ',') -ceq (@($expectedHashes) -join ',') -and $deliveredBlobs -cnotcontains $oldBlobHash) 'Scenario 2: the delivery contains a member that does not belong to the sealed generation.'
            $deliveredManifest=Read-WsmJson (Join-Path $deliveredRoot 'manifest.json')
            Check ($deliveredManifest.PackageId -ceq $packageTwo.Manifest.PackageId -and $deliveredManifest.Generation -eq $packageTwo.Manifest.Generation -and $deliveredManifest.ArtifactsHash -ceq $packageTwo.Manifest.ArtifactsHash) 'Scenario 2: delivered manifest is not the sealed generation.'
            Check ([IO.File]::Exists($oldBlobPath)) 'Scenario 2: evidence of the interrupted capture was deleted by the retry.'
            Write-Host 'PASS: 16.6-2 interrupted second channel: partial kept, parent not successful, retry sealed only the new capture.'

            # 16.6-2b: the consistency window is gone for good (the freeze receipt expired and the source was handed back).
            # The old partial stays untouched, the stale freeze cannot be continued, and only after the real SourceResume does a NEW
            # attempt seal a generation that consists of the new bytes only.
            $script:rlCrashStub={param($SourcePath,$BlobRoot,$ChunkBytes,$BytesPerSecond,$CancellationToken=$null);if(([string]$SourcePath).StartsWith($script:rlCrashDir,[StringComparison]::OrdinalIgnoreCase)){throw 'Injected crash while the second channel scope is being captured.'};& $script:rlOrigPayload $SourcePath $BlobRoot $ChunkBytes $BytesPerSecond $CancellationToken}
            $stalePlan=New-ReliabilityPlan 'stale' 'OwnerFreeze' 'NonC'
            $staleAuth=New-FreezeAuthorization $stalePlan
            Set-SourceBytes 'generation-three'
            $staleOldA1=Sha $fileA1
            $opStale=[Guid]::NewGuid().ToString('D')
            Set-Item -Path Function:\script:Write-WsmPayloadFile -Value $script:rlCrashStub
            try{$staleCrash=Try-Run {Start-Backup $stalePlan $opStale 'Directory' 0 $staleAuth}}finally{Set-Item -Path Function:\script:Write-WsmPayloadFile -Value $script:rlOrigPayload}
            $staleAttempt=Get-Attempt $stalePlan $opStale
            Check ($staleCrash -and $staleAttempt.Stage -ceq 'Failed' -and $staleAttempt.ResumeStage -ceq 'Authorized' -and $staleAttempt.Freeze -and $staleAttempt.SourceResumeRequired -and -not $staleAttempt.CoreExport) 'Scenario 2b: the frozen attempt that crashed in the second channel was not recorded as failed with a source resume still required.'
            $staleResult=ConvertTo-WsmWizardBackupResult $staleAttempt $opStale
            Check ((Get-WsmOperationStatusCode $staleResult) -eq 1 -and $staleResult.SourceResumeRequired -and -not $staleResult.Delivery) 'Scenario 2b: the parent reports success while the source freeze is still unresolved.'
            $stalePackages=Join-Path ([string]$staleAttempt.OutputRoot) 'packages'
            $stalePartials=@(Find-Files $stalePackages @('artifacts.jsonl.partial'));Check ($stalePartials.Count -eq 1) 'Scenario 2b: no partial index was kept for inspection.'
            $stalePartialHash=Sha $stalePartials[0].FullName;$stalePackagesTree=Tree $stalePackages
            Set-SourceBytes 'generation-four'
            $receiptPath=[string]$staleAttempt.Freeze.Path
            $receipt=Read-WsmJson $receiptPath;$receipt.ProducedUtc=[DateTimeOffset]::UtcNow.AddHours(-3).ToString('o');$receipt.ExpiresUtc=[DateTimeOffset]::UtcNow.AddHours(-1).ToString('o');Write-WsmJson $receiptPath $receipt
            $staleAttemptPath=Join-Path (Get-WsmWizardBackupRoot $sourceRoot $stalePlan.PairId) ($opStale+'.json')
            $staleRecord=Read-WsmJson $staleAttemptPath;$staleRecord.Freeze.SHA256=Sha $receiptPath;Write-WsmJson $staleAttemptPath $staleRecord
            $staleJob=[pscustomobject]@{jobId=$opStale;action='StartBackup';status='Failed';role='Source';workspace=[IO.Path]::GetFullPath($sourceRoot);pairId=$stalePlan.PairId;outputs=@([pscustomobject]@{AttemptId=$opStale})}
            $retryAuth=New-FreezeAuthorization $stalePlan
            $opStaleRetry=[Guid]::NewGuid().ToString('D');$retryToken=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $stalePlan.PairId -PlanHash $stalePlan.PlanHash -OperationId $opStaleRetry
            $staleRetryError=Try-Run {Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $stalePlan.PairId -OperationId $opStaleRetry -Owner $freezeOwner -Evidence $freezeEvidenceText -FreezeAuthorization -FreezeExternalEvidencePath $retryAuth.Proof.Path -FreezeExternalEvidenceHash $retryAuth.Proof.SHA256 -Jobs @($staleJob) -CancellationToken $retryToken -DeliveryMode Directory -VolumeBytes 0}
            Check ($staleRetryError -and $staleRetryError.Message -like '*expired*') ('Scenario 2b: continuing a stale freeze was not refused as expired: '+$staleRetryError)
            Check ((Sha $stalePartials[0].FullName) -ceq $stalePartialHash -and (Tree $stalePackages) -ceq $stalePackagesTree -and (Count-AttemptFiles $stalePlan) -eq 1 -and (Get-Attempt $stalePlan $opStale).Stage -ceq 'Failed' -and @(Find-Files $stalePackages @('manifest.json')).Count -eq 0) 'Scenario 2b: the refused continuation changed the old partial, sealed something, or created a second attempt.'
            # Real SourceResume (typed text consumer), then a new attempt with newly observed freeze evidence.
            $stalePlanRef=Get-WsmWizardCurrentApprovedPlan $sourceRoot $stalePlan.PairId (Read-WsmOutputProfile $sourceRoot) $null @()
            $freezeReceipt=Read-WsmFreezeRecord $receiptPath (Sha $receiptPath) $stalePlan.Plan $stalePlan.PlanHash -AllowExpired
            $sourceAttemptPath=[string]$freezeReceipt.SourceAttemptPath;$sourceAttemptHash=[string]$freezeReceipt.SourceAttemptHash
            $sourceAttempt=Read-WsmSourceAttempt $sourceAttemptPath $sourceAttemptHash $stalePlan.Plan $stalePlan.PlanHash
            $pairsRoot=Join-Path $sourceRoot 'pairs'
            $resumeProof=New-WsmSourceResumeEvidenceFixture -Plan $stalePlan.Plan -PlanHash $stalePlan.PlanHash -AttemptId $sourceAttempt.State.AttemptId -AttemptHash $sourceAttemptHash -Root $Root -Owner $freezeOwner
            $stalePairChoices=@(Get-WsmWizardReceivedPlanChoices $sourceRoot (Read-WsmOutputProfile $sourceRoot));$stalePairIndex=0;for($i=0;$i -lt $stalePairChoices.Count;$i++){if([string]$stalePairChoices[$i].pairId -ceq $stalePlan.PairId){$stalePairIndex=$i+1}};if($stalePairIndex -lt 1){throw "Scenario 2b: the pair is not offered by the typed-text pair picker."}
            $resumeAnswers=@{
                '選擇操作情境角色'='1';'選配對編號'=[string]$stalePairIndex;'輸入完整操作識別碼'='SourceResume';
                'PlanPath'=$stalePlanRef.Path;'ExpectedHash'=$stalePlan.PlanHash;'SourceAttemptPath'=$sourceAttemptPath;'SourceAttemptHash'=$sourceAttemptHash;
                'SourceStateDirectory'=$pairsRoot;'Owner'=$freezeOwner;'OwnershipEvidence'='Fixture confirms target stopped and writes reconciled.';
                'Acknowledgement'=('SOURCE-OWNERSHIP-RESTORED '+$stalePlan.PairId);'ResumeExternalEvidencePath'=$resumeProof.Path;'ResumeExternalEvidenceHash'=$resumeProof.SHA256;
                'TaskReconciliationPath'='';'TaskReconciliationHash'='';'APPLY'='APPLY'
            }
            $resumeReader={param($prompt) foreach($key in @($resumeAnswers.Keys|Sort-Object Length -Descending)){if(([string]$prompt).Contains([string]$key)){return [string]$resumeAnswers[$key]}};throw ('Unexpected SourceResume prompt: '+$prompt)}.GetNewClosure()
            $resumeResult=Invoke-WsmTypedTextOperation -Workspace $sourceRoot -PromptReader $resumeReader
            $resumeJobs=@(Get-WsmTextWizardJobs $sourceRoot $stalePlan.PairId 'Source')
            Check ($resumeResult.Status -ceq 'Applied' -and @($resumeResult.Result|Where-Object Status -ceq 'SourceResumed').Count -eq 1) 'Scenario 2b: the real SourceResume consumer did not resume the source.'
            $finalAuth=New-FreezeAuthorization $stalePlan
            $opFinal=[Guid]::NewGuid().ToString('D');$finalToken=New-WsmCancellationToken -StateDirectory $pairsRoot -PairId $stalePlan.PairId -PlanHash $stalePlan.PlanHash -OperationId $opFinal
            $final=Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $stalePlan.PairId -OperationId $opFinal -Owner $freezeOwner -Evidence $freezeEvidenceText -FreezeAuthorization -FreezeExternalEvidencePath $finalAuth.Proof.Path -FreezeExternalEvidenceHash $finalAuth.Proof.SHA256 -Jobs (@($staleJob)+$resumeJobs) -CancellationToken $finalToken -DeliveryMode Directory -VolumeBytes 0
            $finalAttempt=Get-Attempt $stalePlan $opFinal
            Check ($final.Status -cin @('Delivered','ReviewRequired') -and $final.Delivery -and $final.NonCStatus -ceq 'RequiresTargetTransferAndManagerResultImport' -and (Get-WsmOperationStatusCode $final) -ne 0 -and $finalAttempt.AttemptId -cne $staleAttempt.AttemptId -and [string]$finalAttempt.OutputRoot -cne [string]$staleAttempt.OutputRoot -and $finalAttempt.FreezeEpoch -cne $staleAttempt.FreezeEpoch) 'Scenario 2b: the new attempt after SourceResume did not get its own output root and freeze epoch.'
            $finalPackage=Test-WsmMigrationPackage ([string]$finalAttempt.CoreExport.ManifestPath) ([string]$finalAttempt.CoreExport.SHA256)
            $finalRows=@(Read-WsmArtifactLines (Join-Path $finalPackage.Root 'artifacts.jsonl') $finalPackage.Manifest.ArtifactsHash|Where-Object {-not $_.Directory})
            $finalExpected=@(Sha $fileA1;Sha $fileB1;Sha $fileB2)|Sort-Object
            Check ((@($finalRows|ForEach-Object {[string]$_.Data.Hash}|Sort-Object) -join ',') -ceq (@($finalExpected) -join ',') -and @($finalRows|Where-Object {$_.Data.Hash -ceq $staleOldA1}).Count -eq 0 -and $finalPackage.Manifest.Final -and $finalPackage.Manifest.Generation -eq 1) 'Scenario 2b: the generation sealed after the source was handed back is not made of the new bytes only.'
            Check ((Sha $stalePartials[0].FullName) -ceq $stalePartialHash -and (Tree $stalePackages) -ceq $stalePackagesTree) 'Scenario 2b: the old partial was changed by the new attempt.'
            $parentAfter=ConvertTo-WsmWizardBackupResult (Get-Attempt $stalePlan $opStale) $opStale
            Check ((Get-WsmOperationStatusCode $parentAfter) -eq 1 -and -not $parentAfter.Delivery -and -not $parentAfter.CoreExport) 'Scenario 2b: the interrupted parent was reported as successful after the child attempt finished.'
            Write-Host 'PASS: 16.6-2b expired consistency: stale freeze refused, old partial untouched, new attempt sealed only new bytes.'

            # ================= 16.6-3: sealed, delivery interrupted, resumed with zero source reads and no new freeze =================
            $deliverPlan=New-ReliabilityPlan 'deliver' 'Immutable'
            function Get-MemberMap([string]$Directory){$map=@{};foreach($file in @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Force)){$map[$file.FullName.Substring($Directory.TrimEnd('\').Length+1)]=Sha $file.FullName};$map}
            function Set-SourceDeny([bool]$On){
                $me=[Security.Principal.WindowsIdentity]::GetCurrent().User
                foreach($dir in @($dataA,$dataB)){
                    $acl=Get-Acl -LiteralPath $dir
                    if($On){$rule=New-Object Security.AccessControl.FileSystemAccessRule($me,[Security.AccessControl.FileSystemRights]::ReadData,[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Deny);$acl.AddAccessRule($rule)}
                    else{foreach($existing in @($acl.Access|Where-Object {$_.AccessControlType -eq 'Deny' -and $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]) -eq $me})){[void]$acl.RemoveAccessRuleSpecific($existing)}}
                    Set-Acl -LiteralPath $dir -AclObject $acl
                }
            }
            foreach($mode in @(@('Directory',0),@('Zip',134217728))){
                $modeName=[string]$mode[0];$modeVolume=[long]$mode[1]
                Set-SourceBytes ('generation-delivery-'+$modeName)
                $opBase=[Guid]::NewGuid().ToString('D');$baseline=Start-Backup $deliverPlan $opBase $modeName $modeVolume
                Check ($baseline.Status -ceq 'Delivered') ('Scenario 3 ('+$modeName+'): the uninterrupted baseline did not deliver.')
                $opCut=[Guid]::NewGuid().ToString('D');$script:rlCopyCalls=0
                if($modeName -ceq 'Directory'){function script:Copy-WsmOutputMember {param([string]$Source,[string]$Destination,[long]$ExpectedBytes,[string]$ExpectedHash,$CancellationToken=$null);$script:rlCopyCalls++;if($script:rlCopyCalls -eq 2){throw (New-Object IO.IOException('Injected delivery interruption.'))};& $script:rlOrigCopyMember $Source $Destination $ExpectedBytes $ExpectedHash $CancellationToken}}
                else{function script:Copy-WsmCancellableStream {param($InputStream,$OutputStream,$CancellationToken=$null,[string]$Phase='CopyBuffer');if($Phase -ceq 'ZipWriteBuffer'){$script:rlCopyCalls++;if($script:rlCopyCalls -eq 2){throw (New-Object IO.IOException('Injected delivery interruption.'))}};& $script:rlOrigStreamCopy $InputStream $OutputStream $CancellationToken $Phase}}
                try{$cutError=Try-Run {Start-Backup $deliverPlan $opCut $modeName $modeVolume}}finally{Set-Item -Path Function:\script:Copy-WsmOutputMember -Value $script:rlOrigCopyMember;Set-Item -Path Function:\script:Copy-WsmCancellableStream -Value $script:rlOrigStreamCopy}
                $cutAttempt=Get-Attempt $deliverPlan $opCut
                Check ($cutError -and $cutError.Message -like '*Injected delivery interruption*' -and $cutAttempt.Stage -ceq 'Failed' -and $cutAttempt.ResumeStage -ceq 'PackageVerified' -and $cutAttempt.CoreExport.Sealed -and -not $cutAttempt.Delivery) ('Scenario 3 ('+$modeName+'): the interrupted delivery was not recorded as a sealed package with delivery pending.')
                $sealedDirectory=Split-Path -Parent ([string]$cutAttempt.CoreExport.ManifestPath);$sealedMap=Get-MemberMap $sealedDirectory;$sealedTreeBefore=Tree $sealedDirectory
                $freezeFoldersBefore=Count-FreezeFolders $deliverPlan
                # The business resumes on the source: every business byte changes, then reading the source is forbidden outright.
                Set-SourceBytes ('business-resumed-'+$modeName)
                Set-SourceDeny $true
                $denied=$false;try{[void][IO.File]::ReadAllBytes($fileA1)}catch [UnauthorizedAccessException]{$denied=$true}
                if(-not $denied){Set-SourceDeny $false;throw 'Scenario 3: the deny ACL fixture does not block reading the source file, so a zero-read result would prove nothing.'}
                foreach($name in $script:rlCounterNames){Install-Counter $name}
                $opResume=[Guid]::NewGuid().ToString('D')
                try{$resumed=Start-Backup $deliverPlan $opResume $modeName $modeVolume;$resumeCalls=@{};foreach($name in $script:rlCounterNames){$resumeCalls[$name]=$script:rlCalls[$name]}}
                finally{foreach($name in @($script:rlCounterNames)){Remove-Counter $name};Set-SourceDeny $false}
                foreach($name in $script:rlCounterNames){Check ($resumeCalls[$name] -eq 0) ('Scenario 3 ('+$modeName+'): resumed delivery called '+$name+' '+$resumeCalls[$name]+' time(s); the source must not be touched.')}
                $resumedAttempt=Get-Attempt $deliverPlan $opResume
                Check ($resumed.Status -ceq 'Delivered' -and $resumedAttempt.AttemptId -ceq $cutAttempt.AttemptId -and [int]$resumedAttempt.ResumeCount -eq 1) ('Scenario 3 ('+$modeName+'): the resume did not finish the same attempt.')
                Check ((Count-FreezeFolders $deliverPlan) -eq $freezeFoldersBefore -and (Tree $sealedDirectory) -ceq $sealedTreeBefore) ('Scenario 3 ('+$modeName+'): the resume froze again or changed the sealed package.')
                Check ([string]$resumedAttempt.CoreExport.SHA256 -ceq [string]$cutAttempt.CoreExport.SHA256 -and [string]$resumedAttempt.CoreExport.ManifestPath -ceq [string]$cutAttempt.CoreExport.ManifestPath) ('Scenario 3 ('+$modeName+'): the resume delivered a different package than the one that was sealed.')
                if($modeName -ceq 'Directory'){
                    $resumedMap=Get-MemberMap ([string]$resumed.Delivery.Directory);$baselineMap=Get-MemberMap ([string]$baseline.Delivery.Directory)
                    foreach($relative in @($resumedMap.Keys)){
                        $normalized=$relative.Replace('\','/')
                        if(-not $sealedMap.ContainsKey($relative)){throw ('Scenario 3 (Directory): delivered member is not part of the sealed package: '+$relative)}
                        if($resumedMap[$relative] -cne $sealedMap[$relative]){throw ('Scenario 3 (Directory): delivered member differs from the sealed package: '+$relative)}
                    }
                    foreach($relative in @($resumedMap.Keys|Where-Object {$_ -like 'payload\*' -or $_ -ceq 'plan.json' -or $_ -ceq 'artifacts.jsonl'})){if(-not $baselineMap.ContainsKey($relative) -or $baselineMap[$relative] -cne $resumedMap[$relative]){throw ('Scenario 3 (Directory): resumed member differs from the one-pass delivery: '+$relative)}}
                    Check (@($baselineMap.Keys|Where-Object {$_ -like 'payload\*'}).Count -eq @($resumedMap.Keys|Where-Object {$_ -like 'payload\*'}).Count -and @($resumedMap.Keys|Where-Object {$_ -like 'payload\*'}).Count -ge 3) 'Scenario 3 (Directory): the resumed payload set differs in size from the one-pass delivery.'
                }else{
                    $script:rlFp=('b'*64)
                    try{$zipImport=Import-WsmPackageZip -TransportPath $resumed.Delivery.Path -ExpectedHash $resumed.Delivery.SHA256 -OutputDirectory (Join-Path $Root 'scenario3-zip-imported')}finally{$script:rlFp=('a'*64)}
                    $importedMap=Get-MemberMap (Split-Path -Parent $zipImport.ManifestPath)
                    foreach($relative in @($importedMap.Keys)){if($sealedMap.ContainsKey($relative) -and $sealedMap[$relative] -cne $importedMap[$relative]){throw ('Scenario 3 (Zip): imported member differs from the sealed package: '+$relative)}}
                    foreach($relative in @($sealedMap.Keys|Where-Object {$_ -like 'payload\*' -or $_ -ceq 'manifest.json' -or $_ -ceq 'artifacts.jsonl' -or $_ -ceq 'plan.json'})){if(-not $importedMap.ContainsKey($relative)){throw ('Scenario 3 (Zip): sealed member is missing from the resumed ZIP: '+$relative)}}
                    $transport=Read-WsmTrustedJson $resumed.Delivery.Path $resumed.Delivery.SHA256
                    foreach($volume in @($transport.Volumes)){if((Sha (Join-Path (Split-Path -Parent $resumed.Delivery.Path) $volume.Name)) -cne ([string]$volume.Hash).ToLowerInvariant()){throw 'Scenario 3 (Zip): a resumed volume differs from its descriptor.'}}
                }
                Write-Host ('PASS: 16.6-3 '+$modeName+' delivery interrupted after sealing; resume read nothing from the source, froze nothing and delivered the sealed bytes.')
            }
        } finally {
            foreach($name in @($script:rlOrig.Keys)){Remove-Counter $name}
        }
        Write-Host ('PASS: N4 reliability scenarios ('+$script:rlChecks+' checks).')
    } $root $evidenceFixturePath
} finally {
    $full=[IO.Path]::GetFullPath($root);$driveRoot=[IO.Path]::GetPathRoot($full)
    if($full -ieq $driveRoot -or [IO.Path]::GetDirectoryName($full) -ine $driveRoot -or [IO.Path]::GetFileName($full) -notlike 'wsmrl-*'){throw 'Unsafe cleanup path.'}
    if([IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
    cmd.exe /c ('subst '+$driveLetter+': /D')
}
