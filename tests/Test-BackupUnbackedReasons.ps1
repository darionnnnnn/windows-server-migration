#requires -Version 5.1
# N3: unbacked reasons. BundleExcluded regions need the scan the sealed plan is bound to; CaptureFailed and NotVerified are attempt-level facts (capture is all-or-nothing), never per-item reasons.
# Runs on real sealed plans and a real failing backup; only host qualification is substituted.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$driveLetter=(@('R','S','T','U','V','W','X','Y','Z') | Where-Object { -not (Test-Path -LiteralPath ($_+':\')) } | Select-Object -First 1)
if(-not $driveLetter){throw 'No free temporary drive letter is available for the short-path payload test.'}
cmd.exe /c ('subst '+$driveLetter+': "'+$tempBase.TrimEnd('\')+'"')
if($LASTEXITCODE -ne 0){throw 'Unable to create a temporary drive alias for the unbacked reasons test.'}
$root=Join-Path ($driveLetter+':\') ('wsmur-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root)
        $check={param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
        $script:backupFixtureFingerprint=('a'*64)
        function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:backupFixtureFingerprint;Name='workbench-fixture-source';OS='Fixture Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function script:Get-WsmPreflight {[pscustomobject]@{OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true;PowerShellVersion='5.1';ExecutionPolicy='AllSigned';LanguageMode='FullLanguage'}}
        $script:backupFixtureInventoryPath=''
        function script:Export-WsmInventory {param([string]$OutputDirectory,[switch]$DeepDiscovery);if(-not $script:backupFixtureInventoryPath){throw 'Fixture inventory observation was not initialized.'};[pscustomobject]@{Path=$script:backupFixtureInventoryPath;SHA256=(Get-FileHash -LiteralPath $script:backupFixtureInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()}}
        $sourceRoot=Join-Path $Root 'source-work';$targetRoot=Join-Path $Root 'target-work';$managerRoot=Join-Path $Root 'manager-work'
        $sourceEnrollment=Initialize-WsmOutputWorkspace $sourceRoot Source
        $script:backupFixtureFingerprint=('b'*64);$targetEnrollment=Initialize-WsmOutputWorkspace $targetRoot Target
        $targetIdentityPath=Join-Path (Join-Path $targetRoot ('targets\'+$targetEnrollment.HostId)) 'target-identity.json';$targetIdentityHash=(Get-FileHash -LiteralPath $targetIdentityPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:backupFixtureFingerprint=('a'*64)
        $source=[pscustomobject]@{HostId=$sourceEnrollment.HostId;Fingerprint=('a'*64);Name='fixture-source'}
        $fixtureHash=('c'*64)
        $policyPrefix='Protected or package area excluded by policy: '
        $installRoot='C:\Vendor\Contoso App'

        # ---- 1. BundleExcluded / ProtectedArea classification comes from the recorded policy reason, never from names ----
        $areas=@(
            [pscustomobject]@{Path='C:\Program Files';Reason=($policyPrefix+'C:\Program Files')},
            [pscustomobject]@{Path=$installRoot;Reason=($policyPrefix+$installRoot)},
            [pscustomobject]@{Path='C:\Windows';Reason=($policyPrefix+'C:\Windows')},
            [pscustomobject]@{Path=(Join-Path $Root 'source-work');Reason=($policyPrefix+(Join-Path $Root 'source-work'))},
            [pscustomobject]@{Path='C:\Config.Msi';Reason=($policyPrefix+'Config.Msi')},
            [pscustomobject]@{Path='C:\$Recycle.Bin';Reason=($policyPrefix+'FileScope guard: protected system/software directory: $Recycle.Bin')},
            [pscustomobject]@{Path='C:\Program Files';Reason=($policyPrefix+'C:\Program Files')},
            [pscustomobject]@{Path='C:\Looks Like Software Name';Reason=($policyPrefix+'FileScope guard: drive root')})
        $regionRows=@(Get-WsmBackupExcludedRegionRows $areas (Join-Path $Root 'source-work'))
        $regionByPath=@{};foreach($r in $regionRows){$regionByPath[[string]$r.Path]=$r}
        & $check ($regionRows.Count -eq 7) 'A repeated excluded path must collapse to one region row.'
        & $check ($regionByPath['C:\Program Files'].ReasonCode -ceq 'BundleExcluded' -and $regionByPath[$installRoot].ReasonCode -ceq 'BundleExcluded') 'Program Files and an installed-software root must be BundleExcluded.'
        & $check ($regionByPath['C:\Windows'].ReasonCode -ceq 'ProtectedArea' -and $regionByPath[(Join-Path $Root 'source-work')].ReasonCode -ceq 'ProtectedArea' -and $regionByPath['C:\Config.Msi'].ReasonCode -ceq 'ProtectedArea' -and $regionByPath['C:\$Recycle.Bin'].ReasonCode -ceq 'ProtectedArea') 'Windows, the tool workspace, Config.Msi and guard-protected paths must be ProtectedArea.'
        & $check ($regionByPath['C:\Looks Like Software Name'].ReasonCode -ceq 'ProtectedArea') 'A guard reason must stay ProtectedArea whatever the folder is called.'
        foreach($r in $regionRows){& $check ([bool]$r.Reason -and [bool]$r.NextStep -and $r.Reason -match '[\u4e00-\u9fff]' -and $r.NextStep -match '[\u4e00-\u9fff]') ('Every region needs Chinese reason and next step: '+$r.Path)}
        & $check (@(Get-WsmBackupExcludedRegionRows @() '').Count -eq 0) 'No excluded areas must give an empty list.'
        Write-Host 'PASS: excluded region classes, reasons and next steps.'

        # ---- 2. the scan must be the one the sealed plan is bound to ----
        $sourceProfile=Read-WsmOutputProfile $sourceRoot
        $newScan={param([string]$Fingerprint,[object[]]$ExcludedAreas)
            $scanId=[Guid]::NewGuid().ToString('D')
            $scanDirectory=Get-WsmSourceCandidateScanDirectory $sourceRoot $sourceProfile $scanId
            [void][IO.Directory]::CreateDirectory($scanDirectory)
            $artifact=[pscustomobject][ordered]@{SchemaVersion=1;Kind='SourceCandidateDiscovery';ScanId=$scanId;SourceFingerprint=$Fingerprint;Status='Succeeded';Candidates=@();ExcludedAreas=@($ExcludedAreas)}
            $artifactPath=Join-Path $scanDirectory 'candidates.json';Write-WsmJson $artifactPath $artifact
            [pscustomobject]@{ScanId=$scanId;Path=$artifactPath;Hash=(Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()}
        }
        $newConfirmation={param($Scan,[string]$Fingerprint,[string]$InventoryHash,[string]$ArtifactHash)
            $confirmation=[pscustomobject][ordered]@{SchemaVersion=1;Kind='SourceCandidateConfirmation';ConfirmationId=[Guid]::NewGuid().ToString('D');ScanId=$Scan.ScanId;SourceFingerprint=$Fingerprint;InventoryHash=$InventoryHash;CandidateArtifactHash=$ArtifactHash}
            $staging=Join-Path $Root ('confirmation-'+[Guid]::NewGuid().ToString('N')+'.json');Write-WsmJson $staging $confirmation
            $hash=(Get-FileHash -LiteralPath $staging -Algorithm SHA256).Hash.ToLowerInvariant()
            $reference='assistive/materials/source-candidate/'+$hash+'/confirmation.json'
            $final=Join-Path $sourceRoot $reference.Replace('/','\');[void][IO.Directory]::CreateDirectory((Split-Path -Parent $final));[IO.File]::Move($staging,$final)
            [pscustomobject]@{Reference=$reference;SHA256=$hash;Path=$final}
        }
        $newPlan={param([object[]]$References)[pscustomobject]@{Source=[pscustomobject]@{Fingerprint=('a'*64)};InventoryHash=$fixtureHash;Assistive=[pscustomobject]@{MaterialReferences=@($References)}}}
        $scanA=& $newScan ('a'*64) @($areas)
        $confirmationA=& $newConfirmation $scanA ('a'*64) $fixtureHash $scanA.Hash
        $bound=Get-WsmBackupBoundScanExclusions (& $newPlan @([pscustomobject]@{Reference=$confirmationA.Reference;SHA256=$confirmationA.SHA256})) $sourceRoot $sourceProfile
        & $check ($bound.Binding.Status -ceq 'Bound' -and @($bound.Regions).Count -eq 7 -and @($bound.Binding.Scans).Count -eq 1 -and $bound.Binding.Scans[0].ScanId -ceq $scanA.ScanId -and $bound.Binding.Scans[0].CandidateArtifactHash -ceq $scanA.Hash) 'The scan bound by the sealed plan must supply the excluded regions.'
        $assertNotRecorded={param($Result,[string]$Why)& $check ($null -eq $Result.Regions -and $Result.Binding.Status -ceq 'NotRecorded' -and [bool]$Result.Binding.Reason -and @($Result.Binding.Scans).Count -eq 0) ('Binding must read as not recorded: '+$Why)}
        $ref=[pscustomobject]@{Reference=$confirmationA.Reference;SHA256=$confirmationA.SHA256}
        # no reference at all / plan without Assistive
        & $assertNotRecorded (Get-WsmBackupBoundScanExclusions (& $newPlan @()) $sourceRoot $sourceProfile) 'plan without a candidate confirmation'
        & $assertNotRecorded (Get-WsmBackupBoundScanExclusions ([pscustomobject]@{Source=[pscustomobject]@{Fingerprint=('a'*64)};InventoryHash=$fixtureHash}) $sourceRoot $sourceProfile) 'plan without Assistive'
        # another scan that was never bound: the plan references only scan A, so scan B must not leak in
        $scanB=& $newScan ('a'*64) @([pscustomobject]@{Path='C:\Only In B';Reason=($policyPrefix+'C:\Only In B')})
        $boundAgain=Get-WsmBackupBoundScanExclusions (& $newPlan @($ref)) $sourceRoot $sourceProfile
        & $check (-not (@($boundAgain.Regions | ForEach-Object Path) -contains 'C:\Only In B')) 'A scan that the plan does not reference must never contribute regions.'
        # confirmation points at scan B but cites A's hash -> candidate bytes differ from the cited hash
        $confusedConfirmation=& $newConfirmation $scanB ('a'*64) $fixtureHash $scanA.Hash
        & $assertNotRecorded (Get-WsmBackupBoundScanExclusions (& $newPlan @([pscustomobject]@{Reference=$confusedConfirmation.Reference;SHA256=$confusedConfirmation.SHA256})) $sourceRoot $sourceProfile) 'confirmation cites a hash that is not the scan artifact'
        # artifact changed after the plan was bound
        $scanTampered=& $newScan ('a'*64) @($areas[0])
        $confirmationTampered=& $newConfirmation $scanTampered ('a'*64) $fixtureHash $scanTampered.Hash
        [IO.File]::AppendAllText($scanTampered.Path,' ')
        & $assertNotRecorded (Get-WsmBackupBoundScanExclusions (& $newPlan @([pscustomobject]@{Reference=$confirmationTampered.Reference;SHA256=$confirmationTampered.SHA256})) $sourceRoot $sourceProfile) 'candidates.json changed after confirmation'
        # confirmation bytes changed after the plan sealed its hash
        $scanC=& $newScan ('a'*64) @($areas[0])
        $confirmationC=& $newConfirmation $scanC ('a'*64) $fixtureHash $scanC.Hash
        [IO.File]::AppendAllText($confirmationC.Path,' ')
        & $assertNotRecorded (Get-WsmBackupBoundScanExclusions (& $newPlan @([pscustomobject]@{Reference=$confirmationC.Reference;SHA256=$confirmationC.SHA256})) $sourceRoot $sourceProfile) 'confirmation changed after the plan sealed its hash'
        # confirmation for another inventory / another host
        $confirmationOtherInventory=& $newConfirmation $scanA ('a'*64) ('d'*64) $scanA.Hash
        & $assertNotRecorded (Get-WsmBackupBoundScanExclusions (& $newPlan @([pscustomobject]@{Reference=$confirmationOtherInventory.Reference;SHA256=$confirmationOtherInventory.SHA256})) $sourceRoot $sourceProfile) 'confirmation belongs to another inventory'
        $confirmationOtherHost=& $newConfirmation $scanA ('e'*64) $fixtureHash $scanA.Hash
        & $assertNotRecorded (Get-WsmBackupBoundScanExclusions (& $newPlan @([pscustomobject]@{Reference=$confirmationOtherHost.Reference;SHA256=$confirmationOtherHost.SHA256})) $sourceRoot $sourceProfile) 'confirmation belongs to another host'
        $scanOtherHost=& $newScan ('e'*64) @($areas[0])
        $confirmationScanOtherHost=& $newConfirmation $scanOtherHost ('a'*64) $fixtureHash $scanOtherHost.Hash
        & $assertNotRecorded (Get-WsmBackupBoundScanExclusions (& $newPlan @([pscustomobject]@{Reference=$confirmationScanOtherHost.Reference;SHA256=$confirmationScanOtherHost.SHA256})) $sourceRoot $sourceProfile) 'scan artifact belongs to another host'
        # reference whose hash does not match the plan record
        & $assertNotRecorded (Get-WsmBackupBoundScanExclusions (& $newPlan @([pscustomobject]@{Reference=$confirmationA.Reference;SHA256=('f'*64)})) $sourceRoot $sourceProfile) 'plan hash differs from the reference path'
        # missing scan
        $scanGone=& $newScan ('a'*64) @($areas[0]);$confirmationGone=& $newConfirmation $scanGone ('a'*64) $fixtureHash $scanGone.Hash;Remove-Item -LiteralPath $scanGone.Path -Force
        & $assertNotRecorded (Get-WsmBackupBoundScanExclusions (& $newPlan @([pscustomobject]@{Reference=$confirmationGone.Reference;SHA256=$confirmationGone.SHA256})) $sourceRoot $sourceProfile) 'scan result file missing'
        # two bound scans: one bad link means nothing is shown (no partial union)
        $badAndGood=Get-WsmBackupBoundScanExclusions (& $newPlan @($ref,[pscustomobject]@{Reference=$confirmationTampered.Reference;SHA256=$confirmationTampered.SHA256})) $sourceRoot $sourceProfile
        & $assertNotRecorded $badAndGood 'one of two bound scans is untrustworthy'
        # two good confirmations of different scans merge; two confirmations of the same scan count once
        $scanD=& $newScan ('a'*64) @([pscustomobject]@{Path='C:\Second Scan Area';Reason=($policyPrefix+'C:\Second Scan Area')},$areas[0])
        $confirmationD=& $newConfirmation $scanD ('a'*64) $fixtureHash $scanD.Hash
        $merged=Get-WsmBackupBoundScanExclusions (& $newPlan @($ref,[pscustomobject]@{Reference=$confirmationD.Reference;SHA256=$confirmationD.SHA256})) $sourceRoot $sourceProfile
        & $check ($merged.Binding.Status -ceq 'Bound' -and @($merged.Binding.Scans).Count -eq 2 -and @($merged.Regions).Count -eq 8) 'Two bound scans must merge their regions without duplicating a shared path.'
        $confirmationA2=& $newConfirmation $scanA ('a'*64) $fixtureHash $scanA.Hash
        $same=Get-WsmBackupBoundScanExclusions (& $newPlan @($ref,[pscustomobject]@{Reference=$confirmationA2.Reference;SHA256=$confirmationA2.SHA256})) $sourceRoot $sourceProfile
        & $check ($same.Binding.Status -ceq 'Bound' -and @($same.Binding.Scans).Count -eq 1 -and @($same.Regions).Count -eq 7) 'Two confirmations of one scan must count the scan once.'
        # a bound scan with nothing excluded is "recorded and empty", not "not recorded"
        $scanEmpty=& $newScan ('a'*64) @();$confirmationEmpty=& $newConfirmation $scanEmpty ('a'*64) $fixtureHash $scanEmpty.Hash
        $empty=Get-WsmBackupBoundScanExclusions (& $newPlan @([pscustomobject]@{Reference=$confirmationEmpty.Reference;SHA256=$confirmationEmpty.SHA256})) $sourceRoot $sourceProfile
        & $check ($empty.Binding.Status -ceq 'Bound' -and $null -ne $empty.Regions -and @($empty.Regions).Count -eq 0) 'A bound scan with no excluded area must be an empty recorded list.'
        Write-Host 'PASS: excluded regions require the scan bound by the sealed plan.'

        # ---- 3. result set, offline report and legacy compatibility ----
        $software=[pscustomobject]@{SoftwareRows=@();FeatureRows=@();CoverageGaps=@()}
        $manifestHash='1234567890abcdef'*4;$planHash='fedcba0987654321'*4
        $plan=[pscustomobject]@{Items=@([pscustomobject]@{ItemId='d1';Name='Data';Kind='DataRoot';Category='Storage';NaturalKey='k-d1';Settings=[pscustomobject]@{Path='C:\d1'};Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath='C:\d1';TransferChannel='C'};Dependencies=@()})}
        $rows=@(Get-WsmBackupItemResultRows $plan $null @([pscustomobject]@{ItemId='d1';RelativePath='a';Directory=$false;Data=[pscustomobject]@{Bytes=1}}) $false)
        $xssPath='C:\Vendor\<img src=x onerror=alert(1)>'
        $xssRows=@(Get-WsmBackupExcludedRegionRows @([pscustomobject]@{Path=$xssPath;Reason=($policyPrefix+'C:\Vendor')}) '')
        $metaBound=[pscustomobject]@{PairId='p';AttemptId='a';PlanHash=$planHash;ManifestHash=$manifestHash;InventorySource='TrustedInventory';Software=$software;ExcludedRegions=@($regionRows+$xssRows);ExcludedRegionsBinding=$bound.Binding}
        $boundPath=Join-Path $Root 'bound.json';$boundExport=Export-WsmBackupItemResults $boundPath $rows $metaBound
        $boundDoc=Read-WsmJson $boundPath
        & $check (@($boundDoc.ExcludedRegions).Count -eq 8 -and $boundDoc.ExcludedRegionsBinding.Status -ceq 'Bound' -and @($boundDoc.CoverageRegions).Count -eq 0) 'ExcludedRegions must be its own list and must not be mixed into CoverageRegions.'
        & $check (@($boundDoc.Rows).Count -eq 1) 'Excluded regions must never become item rows.'
        $boundReport=Export-WsmBackupOfflineReport $boundPath $boundExport.SHA256 (Join-Path $Root 'bound.html')
        $boundHtml=[IO.File]::ReadAllText($boundReport.Path,[Text.Encoding]::UTF8)
        & $check ($boundHtml.Contains('id="tbl-excluded"') -and $boundHtml.Contains('data-csv="backup-excluded-regions.csv"') -and $boundHtml.Contains('data-csv-meta="region"') -and $boundHtml.Contains('data-reason="BundleExcluded"') -and $boundHtml.Contains('data-reason="ProtectedArea"')) 'The report must list excluded regions with their reason codes and a CSV export.'
        & $check ($boundHtml.Contains('套裝軟體本體（安裝目錄），依政策不納入備份') -and $boundHtml.Contains('在新機重新安裝該軟體') -and $boundHtml.Contains('系統、工具或受保護區域，依政策不納入備份')) 'The report must carry the Chinese reason and next step of both region classes.'
        & $check ($boundHtml.Contains('1:區域類別') -and $boundHtml.Contains('data-search-label="搜尋區域路徑"')) 'The region table needs its own filter and search label (they must not clash with the item tables).'
        & $check (-not $boundHtml.Contains('<img src=x') -and $boundHtml.Contains('&lt;img src=x')) 'Excluded region paths must be HTML-escaped.'
        # not recorded (binding could not be verified): null list, explicit wording, never an empty table
        $metaNone=[pscustomobject]@{PairId='p';AttemptId='a';PlanHash=$planHash;ManifestHash=$manifestHash;InventorySource='TrustedInventory';Software=$software;ExcludedRegions=$null;ExcludedRegionsBinding=([pscustomobject]@{Status='NotRecorded';Reason='x';Scans=@()})}
        $nonePath=Join-Path $Root 'none.json';$noneExport=Export-WsmBackupItemResults $nonePath $rows $metaNone
        $noneDoc=Read-WsmJson $nonePath
        & $check ($noneDoc.PSObject.Properties['ExcludedRegions'] -and $null -eq $noneDoc.ExcludedRegions -and $noneDoc.ExcludedRegionsBinding.Status -ceq 'NotRecorded') 'An unverifiable binding must be stored as a null list with a NotRecorded binding.'
        $noneHtml=[IO.File]::ReadAllText((Export-WsmBackupOfflineReport $nonePath $noneExport.SHA256 (Join-Path $Root 'none.html')).Path,[Text.Encoding]::UTF8)
        & $check ($noneHtml.Contains('套裝本體與受保護區域') -and -not $noneHtml.Contains('id="tbl-excluded"') -and $noneHtml.Contains('此結果集未記錄')) 'A not-recorded binding must say so and must not render a table.'
        # bound but empty
        $metaEmpty=[pscustomobject]@{PairId='p';AttemptId='a';PlanHash=$planHash;ManifestHash=$manifestHash;InventorySource='TrustedInventory';Software=$software;ExcludedRegions=@();ExcludedRegionsBinding=$empty.Binding}
        $emptyPath=Join-Path $Root 'empty-excluded.json';$emptyExport=Export-WsmBackupItemResults $emptyPath $rows $metaEmpty
        & $check ([IO.File]::ReadAllText((Export-WsmBackupOfflineReport $emptyPath $emptyExport.SHA256 (Join-Path $Root 'empty-excluded.html')).Path,[Text.Encoding]::UTF8).Contains('沒有記錄到被排除的區域')) 'A recorded empty list must say that nothing was excluded.'
        # older writers (no binding property) and schema 1 documents stay readable and read as not recorded
        $metaOld=[pscustomobject]@{PairId='p';AttemptId='a';PlanHash=$planHash;ManifestHash=$manifestHash;InventorySource='TrustedInventory';Software=$software}
        $oldPath=Join-Path $Root 'old.json';$oldExport=Export-WsmBackupItemResults $oldPath $rows $metaOld
        $oldDoc=Read-WsmJson $oldPath
        & $check (-not $oldDoc.PSObject.Properties['ExcludedRegions'] -and -not $oldDoc.PSObject.Properties['ExcludedRegionsBinding']) 'A caller that does not pass a binding must not invent excluded regions.'
        & $check ([IO.File]::ReadAllText((Export-WsmBackupOfflineReport $oldPath $oldExport.SHA256 (Join-Path $Root 'old.html')).Path,[Text.Encoding]::UTF8).Contains('此結果集未記錄')) 'An older result set must read as not recorded.'
        $legacyPath=Join-Path $Root 'legacy.json'
        Write-WsmJson $legacyPath ([pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='old';Kind='BackupItemResults';PairId='p';AttemptId='a';PlanHash=$planHash;ManifestHash=$manifestHash;InventorySource='TrustedInventory';GeneratedUtc='2026-10-20T00:00:00Z';Counts=[pscustomobject]@{Total=1};Software=$software;Rows=@($rows | Select-Object -Property * -ExcludeProperty Workloads,RestoreCondition)})
        $legacyHtml=[IO.File]::ReadAllText((Export-WsmBackupOfflineReport $legacyPath (Get-FileHash -LiteralPath $legacyPath -Algorithm SHA256).Hash (Join-Path $Root 'legacy.html')).Path,[Text.Encoding]::UTF8)
        & $check ($legacyHtml.Contains('此結果集未記錄') -and -not $legacyHtml.Contains('id="tbl-excluded"')) 'A schema 1 result set must read as not recorded for excluded regions.'
        Write-Host 'PASS: result set, report and legacy compatibility for excluded regions.'

        # ---- 4. NotVerified and CaptureFailed are never invented as item reasons ----
        $reasonCodes=New-Object 'System.Collections.Generic.HashSet[string]'
        $variantPlans=New-Object 'System.Collections.Generic.List[object]'
        foreach($decision in @('Include','Exclude','Pending')){foreach($adapter in @('FileScope','Service','Certificate','ManualWorkflow')){foreach($channel in @('C','NonC','External')){
            $variantSpec=[pscustomobject]@{Adapter=$adapter;SourcePath='C:\v';TransferChannel=$channel}
            $variantPlans.Add([pscustomobject]@{Items=@([pscustomobject]@{ItemId=('v-'+$decision+$adapter+$channel);Name='v';Kind='DataRoot';Category='Storage';NaturalKey='k';Settings=[pscustomobject]@{};Decision=$decision;MigrationSpec=$variantSpec;Dependencies=@()})})
        }}}
        foreach($variantPlan in $variantPlans){
            foreach($variantArtifacts in @(@(),@([pscustomobject]@{ItemId=[string]$variantPlan.Items[0].ItemId;RelativePath='a';Directory=$false;Data=[pscustomobject]@{Bytes=1}}))){
                foreach($offline in @($true,$false)){
                    foreach($variantRow in @(Get-WsmBackupItemResultRows $variantPlan ([pscustomobject]@{Items=@([pscustomobject]@{ItemId=[string]$variantPlan.Items[0].ItemId;Name='v';Kind='DataRoot';Category='Storage';NaturalKey='k';Settings=[pscustomobject]@{};Status='Failed'})}) @($variantArtifacts) $offline)){[void]$reasonCodes.Add([string]$variantRow.ReasonCode)}
                }
            }
        }
        & $check ($reasonCodes.Count -ge 8) 'The variant sweep must exercise many different reasons.'
        & $check (-not $reasonCodes.Contains('CaptureFailed') -and -not $reasonCodes.Contains('NotVerified')) 'CaptureFailed and NotVerified have no per-item source in the result set and must never be produced.'
        $unreadable=@(Get-WsmBackupItemResultRows ([pscustomobject]@{Items=@()}) ([pscustomobject]@{Items=@([pscustomobject]@{ItemId='bad';Name='Broken';Kind='DataRoot';Category='Storage';NaturalKey='k';Settings=[pscustomobject]@{};Status='Failed'})}) @() $false)
        & $check ($unreadable.Count -eq 1 -and $unreadable[0].ReasonCode -cne 'CaptureFailed' -and $unreadable[0].ReasonCode -ceq 'NotSelected') 'A discovery failure status alone must not turn into a capture failure reason.'
        Write-Host 'PASS: no fabricated per-item CaptureFailed / NotVerified reasons.'

        # ---- 5. a real failed backup: capture is all-or-nothing, the attempt names the failed item ----
        $dataOk=Join-Path $Root 'data-ok';$dataBad=Join-Path $Root 'data-bad'
        foreach($dir in @($dataOk,$dataBad)){[void][IO.Directory]::CreateDirectory($dir);[IO.File]::WriteAllText((Join-Path $dir 'a.txt'),('bytes of '+(Split-Path -Leaf $dir)))}
        $itemOk=New-WsmItem $source.HostId Storage DataRoot 'Okay data folder' 'fixture-ok' @{Path=$dataOk}
        $itemBad=New-WsmItem $source.HostId Storage DataRoot 'Doomed data folder' 'fixture-bad' @{Path=$dataBad}
        $inventory=New-WsmInventory $source 1 @($itemOk,$itemBad);$inventoryPath=Join-Path $Root 'inventory.json';Write-WsmJson $inventoryPath $inventory;$script:backupFixtureInventoryPath=$inventoryPath
        Initialize-WsmWorkspace $managerRoot|Out-Null
        $catalog=Import-WsmInventory $managerRoot $inventoryPath (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash 'fixture-target'
        $revision=0
        foreach($pair in @(@($itemOk,$dataOk),@($itemBad,$dataBad))){
            $spec=[pscustomobject]@{Adapter='FileScope';SourcePath=$pair[1];TargetPath=(Join-Path $Root ('restored-'+(Split-Path -Leaf $pair[1])));TransferChannel='C';ContentSelection='WholeScope';ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='AllowAutoInheritedUpgrade';ConflictPolicy='ReplaceOwned';Owner='Fixture owner';Evidence='Isolated actual bytes test';BusinessChecks=@('Read back each source file')}
            $specPath=Join-Path $Root ('spec-'+[Guid]::NewGuid().ToString('N')+'.json');Write-WsmJson $specPath $spec
            Set-WsmMigrationSpec $managerRoot $catalog.PairId $pair[0].ItemId $specPath (Get-FileHash -LiteralPath $specPath -Algorithm SHA256).Hash $revision
            $revision++
        }
        Set-WsmDecision $managerRoot $catalog.PairId @($itemOk.ItemId,$itemBad.ItemId) Include 'Explicit fixture selection' $revision|Out-Null
        $revision++
        $planPath=Join-Path $Root 'approved-plan.json';$approved=Approve-WsmMigrationPlan $managerRoot $catalog.PairId $targetIdentityPath $targetIdentityHash $planPath $revision 'ISOLATED-PILOT'
        $import=Import-WsmWizardApprovedPlan $sourceRoot Source $planPath $approved.SHA256
        $pairId=[string]$import.PairId
        Remove-Item -LiteralPath $dataBad -Recurse -Force
        $failOperation=[Guid]::NewGuid().ToString('D')
        $thrown=$false;try{Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $pairId -OperationId $failOperation -DeliveryMode Directory -VolumeBytes 0 -Jobs @()|Out-Null}catch{$thrown=$true}
        & $check $thrown 'The backup must fail when one included scope vanished.'
        $failedProfile=Read-WsmOutputProfile $sourceRoot
        $failedAttemptRef=Get-WsmWizardBackupAttemptForOperation $sourceRoot $pairId $failedProfile $failOperation
        $failedAttempt=$failedAttemptRef.Attempt
        & $check ($failedAttempt.Stage -ceq 'Failed' -and $failedAttempt.Error.Code -ceq 'core_export_failed') 'The attempt must be Failed with the capture error code.'
        & $check ($failedAttempt.Error.PSObject.Properties['FailedItem'] -and $failedAttempt.Error.FailedItem.ItemId -ceq $itemBad.ItemId -and $failedAttempt.Error.FailedItem.Name -ceq 'Doomed data folder' -and $failedAttempt.Error.FailedItem.Channel -ceq 'C') 'The attempt must name the item that was being captured when it failed.'
        & $check ($failedAttempt.Error.FailedItem.ErrorKind -match '^[A-Za-z0-9_.]+$' -and $failedAttempt.Error.FailedItem.ErrorClass -cin @('PermissionDenied','NotFound','IOError','Failed')) 'The error is recorded as a class and a type name only.'
        $failedJson=[IO.File]::ReadAllText($failedAttemptRef.Path)
        & $check (-not $failedJson.Contains($dataBad)) 'The failed item record must not copy the source path or the exception message.'
        & $check (-not [IO.File]::Exists((Join-Path (Split-Path -Parent ([string]$failedAttempt.OutputRoot)) 'backup-item-results.json')) -and $failedAttempt.CoreExport -eq $null) 'A failed capture must leave no result set and no sealed export.'
        $failedView=Get-WsmWizardBackupItemResultsView $sourceRoot $pairId
        & $check (-not $failedView.available -and $failedView.PSObject.Properties['failedAttempt'] -and $failedView.failedAttempt.classification -ceq 'CaptureFailed' -and $failedView.failedAttempt.failedItem.ItemId -ceq $itemBad.ItemId -and $failedView.failedAttempt.failedItem.Name -ceq 'Doomed data folder' -and $failedView.failedAttempt.attemptId -ceq $failedAttempt.AttemptId) 'The workbench view must show the failed attempt and its failed item instead of a result set.'
        & $check ($failedView.failedAttempt.title -match '[\u4e00-\u9fff]' -and $failedView.failedAttempt.detail -match '[\u4e00-\u9fff]' -and $failedView.failedAttempt.nextStep -match '[\u4e00-\u9fff]') 'The failed attempt view needs Chinese text and a next step.'
        # the same attempt is resumed; now the scope exists (the pre-flight estimate passes) and the byte copy itself fails inside the capture loop
        [void][IO.Directory]::CreateDirectory($dataBad);[IO.File]::WriteAllText((Join-Path $dataBad 'a.txt'),'back again')
        $script:n3FailRoot=$dataBad;$script:n3OriginalWrite=(Get-Command Write-WsmPayloadFile -CommandType Function).ScriptBlock
        function script:Write-WsmPayloadFile {param([string]$SourcePath,[string]$BlobDirectory,[int]$ChunkBytes,[int]$BytesPerSecond=0,$CancellationToken=$null)if($SourcePath -like ($script:n3FailRoot+'*')){throw [IO.IOException]::new('sharing violation on a private path')};& $script:n3OriginalWrite $SourcePath $BlobDirectory $ChunkBytes $BytesPerSecond $CancellationToken}
        try{
            $thrown=$false;try{Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $pairId -OperationId ([Guid]::NewGuid().ToString('D')) -DeliveryMode Directory -VolumeBytes 0 -Jobs @()|Out-Null}catch{$thrown=$true}
        }finally{Set-Item -Path Function:\script:Write-WsmPayloadFile -Value $script:n3OriginalWrite}
        & $check $thrown 'The resumed backup must fail inside the capture loop.'
        $loopAttempt=(Get-WsmWizardBackupAttemptForOperation $sourceRoot $pairId $failedProfile $failOperation).Attempt
        & $check ($loopAttempt.AttemptId -ceq $failedAttempt.AttemptId -and $loopAttempt.Stage -ceq 'Failed' -and $loopAttempt.Error.Code -ceq 'core_export_failed') 'The resumed attempt must fail again with the capture error code.'
        & $check ($loopAttempt.Error.FailedItem.ItemId -ceq $itemBad.ItemId -and $loopAttempt.Error.FailedItem.ErrorClass -ceq 'IOError' -and $loopAttempt.Error.FailedItem.ErrorKind -ceq 'System.IO.IOException') 'A failure inside the capture loop must name the item and the error type.'
        & $check (-not ([IO.File]::ReadAllText($failedAttemptRef.Path)).Contains('private path')) 'The exception message must not reach the attempt record.'
        # a failure outside any item (no tag) names no item
        & $check ($null -eq (New-WsmWizardBackupCaptureFailure $plan ([InvalidOperationException]::new('no tag')))) 'An exception without the capture tag must not name an item.'
        $tagged=[InvalidOperationException]::new('tagged');$tagged.Data['WsmCaptureFailedItemId']='not-in-plan'
        & $check ($null -eq (New-WsmWizardBackupCaptureFailure $plan $tagged)) 'A tag that is not a plan item must not be recorded.'
        $taggedOk=[UnauthorizedAccessException]::new('secret path C:\x');$taggedOk.Data['WsmCaptureFailedItemId']='d1'
        $recorded=New-WsmWizardBackupCaptureFailure $plan $taggedOk
        & $check ($recorded.ItemId -ceq 'd1' -and $recorded.ErrorClass -ceq 'PermissionDenied' -and $recorded.ErrorKind -ceq 'System.UnauthorizedAccessException' -and (($recorded | ConvertTo-Json -Compress) -notmatch 'secret')) 'The error class comes from the exception type and the message is never copied.'
        # read-back failure: sealed but not verified, shown at the attempt level, never as an item row
        $verifyAttempt=Read-WsmJson $failedAttemptRef.Path
        $verifyAttempt.Error=[pscustomobject]@{Code='package_test_failed';Message='x'}
        Write-WsmJson $failedAttemptRef.Path $verifyAttempt
        $verifyView=Get-WsmWizardBackupItemResultsView $sourceRoot $pairId
        & $check (-not $verifyView.available -and $verifyView.failedAttempt.classification -ceq 'NotVerified' -and $null -eq $verifyView.failedAttempt.failedItem -and $verifyView.failedAttempt.detail -match '讀回驗證') 'A failed read-back must be shown as NotVerified at the attempt level without an item.'
        Write-Host 'PASS: capture failure is recorded in the attempt and shown by the workbench view; read-back failure is NotVerified at the attempt level.'

        # ---- 6. wiring: the real backup hands the Source profile and workspace to the binding check and stores what it returns ----
        [void][IO.Directory]::CreateDirectory($dataBad);[IO.File]::WriteAllText((Join-Path $dataBad 'a.txt'),'back again, no failure injected')
        $script:n3Spy=@{Calls=0;Profile=$null;Workspace='';PlanHash=''}
        $script:n3StubRegions=@(Get-WsmBackupExcludedRegionRows @([pscustomobject]@{Path='C:\Vendor\Wired Through';Reason=($policyPrefix+'C:\Vendor\Wired Through');Category='BundleExcluded';Contents=[pscustomobject]@{Listed=3;Directories=1;Complete=$true;IncompleteReason='';SkippedReparse=0;Unreadable=0;Counts=[pscustomobject]@{Bundle=1;SuspectedBusinessData=2;Unknown=0};Samples=@([pscustomobject]@{RelativePath='Reports\a.csv';Bytes=10;Class='SuspectedBusinessData';Why='DataDirectory:Reports'});InstallTimeUtc='';InstallTimeTrusted=$false;BundleFiles=@('app.exe')}},[pscustomobject]@{Path='C:\Windows';Reason=($policyPrefix+'C:\Windows')}) '')
        $script:n3OriginalBound=(Get-Command Get-WsmBackupBoundScanExclusions -CommandType Function).ScriptBlock
        function script:Get-WsmBackupBoundScanExclusions {param($Plan,[string]$Workspace,$Profile)$script:n3Spy.Calls++;$script:n3Spy.Profile=$Profile;$script:n3Spy.Workspace=$Workspace;[pscustomobject]@{Regions=$script:n3StubRegions;Binding=[pscustomobject][ordered]@{Status='Bound';Reason='';Scans=@([pscustomobject][ordered]@{ScanId='wired-scan';CandidateArtifactHash=('c'*64);ScanStatus='Succeeded'})}}}
        try{
            $deliveredOperation=[Guid]::NewGuid().ToString('D')
            $delivered=Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $pairId -OperationId $deliveredOperation -DeliveryMode Directory -VolumeBytes 0 -Jobs @()
        }finally{Set-Item -Path Function:\script:Get-WsmBackupBoundScanExclusions -Value $script:n3OriginalBound}
        & $check ($delivered.Stage -ceq 'Delivered' -and $delivered.ItemResults.Status -ceq 'Generated') 'The resumed backup must deliver once the failure is gone.'
        & $check ($script:n3Spy.Calls -eq 1 -and $null -ne $script:n3Spy.Profile -and [string]$script:n3Spy.Profile.Role -ceq 'Source' -and [IO.Path]::GetFullPath($script:n3Spy.Workspace) -ieq [IO.Path]::GetFullPath($sourceRoot)) 'The backup must pass the Source profile and workspace to the scan binding check exactly once.'
        $deliveredDocument=Read-WsmJson ([string]$delivered.ItemResults.Path)
        & $check (@($deliveredDocument.ExcludedRegions).Count -eq 2 -and $deliveredDocument.ExcludedRegionsBinding.Status -ceq 'Bound' -and $deliveredDocument.ExcludedRegionsBinding.Scans[0].ScanId -ceq 'wired-scan') 'The result set must store the regions and the binding the check returned.'
        $deliveredHtml=[IO.File]::ReadAllText(([string]$delivered.OfflineReport.Path),[Text.Encoding]::UTF8)
        & $check ($deliveredHtml.Contains('id="tbl-excluded"') -and $deliveredHtml.Contains('Wired Through')) 'The delivered offline report must list the stored regions.'
        $deliveredView=Get-WsmWizardBackupItemResultsView $sourceRoot $pairId
        & $check ($deliveredView.available -and @($deliveredView.excludedRegions).Count -eq 2 -and -not $deliveredView.PSObject.Properties['failedAttempt']) 'After delivery the view shows the regions and no failed-attempt block.'
        # N9d：同一條真實備份流程，區域列帶結構化 Category／Contents 時，結果集、工作台 view 與離線報告都要呈現「有人工處置項」。
        & $check ($deliveredDocument.ExcludedCompleteness.Status -ceq 'ManualItems' -and $deliveredDocument.ExcludedCompleteness.SuspectedFileCount -eq 2 -and @($deliveredDocument.ExcludedRegions|Where-Object Path -ceq 'C:\Vendor\Wired Through')[0].Contents.Counts.SuspectedBusinessData -eq 2) 'N9d: the stored result set records the manual-handling completeness and the classified contents.'
        & $check ($deliveredView.excludedCompleteness.Status -ceq 'ManualItems' -and $deliveredView.excludedCompleteness.Text -ceq '有人工處置項' -and @($deliveredView.excludedRegions|Where-Object Path -ceq 'C:\Vendor\Wired Through')[0].ManualHandling.Required) 'N9d: the workbench view shows "有人工處置項" and marks the region for manual handling.'
        & $check ($deliveredHtml.Contains('data-status="ManualItems"') -and $deliveredHtml.Contains('有人工處置項') -and $deliveredHtml.Contains('Reports\a.csv')) 'N9d: the delivered offline report shows "有人工處置項" and the suspected file.'
        Write-Host 'PASS: a real backup stores the bound regions and the view/report show them.'
    } $root
}
finally{
    $full=[IO.Path]::GetFullPath($root);$driveRoot=[IO.Path]::GetPathRoot($full)
    if($full -ieq $driveRoot -or [IO.Path]::GetDirectoryName($full) -ine $driveRoot -or [IO.Path]::GetFileName($full) -notlike 'wsmur-*'){throw 'Unsafe cleanup path.'}
    Remove-Item -LiteralPath $full -Recurse -Force
    cmd.exe /c ('subst '+$driveLetter+': /D')
}
Write-Host 'PASS: backup unbacked reasons.'
