#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$tempRoot=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('wsm-c-'+[Guid]::NewGuid().ToString('N').Substring(0,8))))
if([IO.Directory]::Exists($tempRoot)){throw 'Refusing a pre-existing test directory.'}
[void][IO.Directory]::CreateDirectory($tempRoot)
$checks=0
function Check([bool]$Condition,[string]$Message) { $script:checks++;if(-not $Condition){throw $Message};Write-Output ('PASS '+$Message) }
function ExpectFailure([scriptblock]$Action,[string]$Message) { $script:checks++;$failed=$false;try{& $Action}catch{$failed=$true};if(-not $failed){throw $Message};Write-Output ('PASS '+$Message) }
try {
    $workspace=Join-Path $tempRoot 's'
    $null=Initialize-WsmOutputWorkspace -WorkRoot $workspace -Role Source
    $profile=& $module { param($workspace) Read-WsmOutputProfile $workspace } $workspace
    $source=& $module { param($p) [pscustomobject][ordered]@{HostId=[string]$p.HostId;Fingerprint=([string]$p.Fingerprint).ToLowerInvariant();Name='fixture-source';OS='fixture';Version=''} } $profile
    $inventory=& $module { param($source) New-WsmInventory $source 1 @() } $source
    $inventoryPath=Join-Path (Join-Path (Join-Path (Join-Path $workspace 'hosts') $profile.Fingerprint) 'inventory') 'inventory-1.json'
    & $module { param($path,$data) Write-WsmJson $path $data } $inventoryPath $inventory
    $inventoryHash=(Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $jobId=[Guid]::NewGuid().ToString('D')
    $job=[pscustomobject]@{jobId=$jobId;action='SourceInventory';role='Source';workspace=$workspace;status='Succeeded';outputs=@([pscustomobject]@{Path=$inventoryPath;SHA256=$inventoryHash})}
    $null=Set-WsmWizardInventoryBinding -Workspace $workspace -Role Source -JobId $jobId -ExpectedWizardRevision 0 -Jobs @($job)
    $job|Add-Member NoteProperty pairId '' -Force;$job|Add-Member NoteProperty CompletedUtc ([DateTime]::UtcNow.ToString('o')) -Force
    $textInventoryJob=$job|Select-Object *;$textInventoryJob.action='EnrolledInventory'
    & $module { param($workspace,$record) Write-WsmTextJobRecord $workspace $record | Out-Null } $workspace $textInventoryJob
    $projection=Get-WsmWizardProjection -Workspace $workspace -PairId '' -Role Source -Jobs @($job)
    Check (@($projection.actions|Where-Object action -CEQ 'SourceCandidateScan').Count -eq 1) 'verified unpaired Source projection offers candidate scan'
    $registered=& $module { Get-WsmOperationActions }
    Check ($registered.SourceCandidateScan -ceq 'Invoke-WsmSourceCandidateScan') 'source candidate action resolves through registered operation map'
    $sourceActionMetadata=& $module { @(Get-WsmHtmlActionMetadata -Role Source|Where-Object action -CEQ 'SourceCandidateScan'|Select-Object -First 1) }
    $managerActionMetadata=& $module { @(Get-WsmHtmlActionMetadata -Role Manager|Where-Object action -CEQ 'SourceCandidateScan'|Select-Object -First 1) }
    $targetActionMetadata=& $module { @(Get-WsmHtmlActionMetadata -Role Target|Where-Object action -CEQ 'SourceCandidateScan'|Select-Object -First 1) }
    Check (@($sourceActionMetadata).Count -eq 1 -and $sourceActionMetadata[0].roleAvailable -and $sourceActionMetadata[0].requiredRole -ceq 'Source' -and @($managerActionMetadata).Count -eq 1 -and -not $managerActionMetadata[0].roleAvailable -and @($targetActionMetadata).Count -eq 1 -and -not $targetActionMetadata[0].roleAvailable) 'HTML action metadata exposes source candidate scan only for enrolled Source role'
    Check ((Get-Command Invoke-WsmSourceCandidateScan).Parameters.ContainsKey('ScanId') -and (Get-Command Invoke-WsmSourceCandidateScan).Parameters.ContainsKey('ContinueAfterBudgetExhausted') -and -not (Get-Command Invoke-WsmSourceCandidateScan).Parameters.ContainsKey('Root') -and -not (Get-Command Invoke-WsmSourceCandidateScan).Parameters.ContainsKey('SourceRoot')) 'public scan accepts explicit bounded-segment continuation and no caller-controlled root'
    $resolvedRoot=& $module { param($workspace,$profile) Get-WsmSourceCandidateRoot $workspace $profile } $workspace $profile
    Check ($resolvedRoot -ieq 'C:\' -and ([IO.Path]::GetPathRoot([Environment]::SystemDirectory) -ine 'C:\' -or $resolvedRoot -ieq 'C:\')) 'candidate scan root remains explicit local C even when Windows uses another system volume'
    ExpectFailure { Invoke-WsmSourceCandidateScan -Workspace $workspace -Jobs @() } 'scan rejects missing successful source inventory jobs'

    $fixtureRoot=Join-Path $tempRoot 'v'
    $business=Join-Path $fixtureRoot 'Business Data'
    $nested=Join-Path $business 'nested'
    $protected=Join-Path $fixtureRoot 'Windows'
    [void][IO.Directory]::CreateDirectory($nested);[void][IO.Directory]::CreateDirectory($protected)
    $guardProtectedRoots=@('Windows.old','Boot','WindowsImageBackup','WinSxS','ProgramW6432')
    foreach($name in $guardProtectedRoots){$guardDir=Join-Path $fixtureRoot $name;[void][IO.Directory]::CreateDirectory($guardDir);[IO.File]::WriteAllText((Join-Path $guardDir 'protected.bin'),'protected')}
    $programData=Join-Path $fixtureRoot 'ProgramData';$programBusiness=Join-Path $programData 'BusinessData';$programCache=Join-Path $programData 'Package Cache';$programWindows=Join-Path (Join-Path $programData 'Microsoft') 'Windows'
    [void][IO.Directory]::CreateDirectory($programBusiness);[void][IO.Directory]::CreateDirectory($programCache);[void][IO.Directory]::CreateDirectory($programWindows)
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'loose root.txt'),'DO NOT READ THIS CONTENT')
    [IO.File]::WriteAllText((Join-Path $business 'database.bin'),'secret payload')
    [IO.File]::WriteAllText((Join-Path $business 'business.exe'),'business executable candidate')
    [IO.File]::WriteAllText((Join-Path $business 'business.dll'),'business library candidate')
    foreach($name in @('pagefile.sys','swapfile.sys','hiberfil.sys','bootmgr')){[IO.File]::WriteAllText((Join-Path $fixtureRoot $name),'system file fixture')}
    [IO.File]::WriteAllText((Join-Path $nested 'child.json'),'opaque bytes')
    [IO.File]::WriteAllText((Join-Path $protected 'excluded.dll'),'excluded')
    [IO.File]::WriteAllText((Join-Path $programBusiness 'business.dat'),'business-data')
    [IO.File]::WriteAllText((Join-Path $programCache 'package.msi'),'package-cache')
    [IO.File]::WriteAllText((Join-Path $programWindows 'state.dat'),'windows-state')
    $customInstall=Join-Path $fixtureRoot 'Vendor Runtime';[void][IO.Directory]::CreateDirectory($customInstall);[IO.File]::WriteAllText((Join-Path $customInstall 'runtime.dll'),'runtime')
    $portableRoot=Join-Path $fixtureRoot 'Portable Tool';[void][IO.Directory]::CreateDirectory((Join-Path $portableRoot 'bin'));[IO.File]::WriteAllText((Join-Path (Join-Path $portableRoot 'bin') 'tool.exe'),'portable')
    $scanWorkspace=Join-Path $fixtureRoot 'w';$null=Initialize-WsmOutputWorkspace -WorkRoot $scanWorkspace -Role Source
    $scanProfile=& $module { param($workspace) Read-WsmOutputProfile $workspace } $scanWorkspace
    $scanSource=& $module { param($p) [pscustomobject][ordered]@{HostId=[string]$p.HostId;Fingerprint=([string]$p.Fingerprint).ToLowerInvariant();Name='fixture-source';OS='fixture';Version=''} } $scanProfile
    $scanInventory=& $module { param($source) New-WsmInventory $source 1 @() } $scanSource
    $knownWorkloadXml='<Task><Actions><Exec><Command>'+[Security.SecurityElement]::Escape((Join-Path $business 'database.bin'))+'</Command></Exec></Actions></Task>'
    $knownWorkloadItem=& $module { param($hostId,$xml) New-WsmItem $hostId Tasks ScheduledTask 'Fixture task' '\Fixture\Task' @{Xml=$xml} @() Success ScheduledTask } $scanProfile.HostId $knownWorkloadXml
    $scanInventory.Items=@($scanInventory.Items)+@($knownWorkloadItem)
    $softwareId='sw-'+('d'*32);$now=[DateTime]::UtcNow.ToString('o')
    $softwareEntry=[pscustomobject][ordered]@{SoftwareId=$softwareId;Name='Fixture Runtime';Version='1';Publisher='Fixture';Architecture='Unknown';Scope='Machine';SID='';RegistryView='Registry64';Location=$customInstall;SourceKind='Registry';Evidence=[pscustomobject]@{RegistryPath='HKLM:\Software\Fixture';NaturalKey='Fixture Runtime'};ObservedUtc=$now;CaptureStatus='Success';ItemIds=@();AccountContext='Machine'}
    $portableId='sw-'+('e'*32);$portableEntry=[pscustomobject][ordered]@{SoftwareId=$portableId;Name='Portable Tool';Version='1';Publisher='Fixture';Architecture='Unknown';Scope='Portable';SID='';RegistryView='Unknown';Location=(Join-Path $portableRoot 'bin\tool.exe');SourceKind='PortableEvidence';Evidence=[pscustomobject]@{EvidenceKind='PortableMetadata'};ObservedUtc=$now;CaptureStatus='Success';ItemIds=@();AccountContext='Machine'}
    $sourceProjectionHash=& $module { param($value) Get-WsmSoftwareInventoryProjectionHash $value } $scanInventory
    $softwareCatalog=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='fixture';Kind='SoftwareCatalog';Source=[pscustomobject]@{HostId=$scanProfile.HostId;Fingerprint=$scanProfile.Fingerprint;Name='fixture';InventoryRevision=1;InventoryProjectionHash=$sourceProjectionHash};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=$now;CaptureIdentity='fixture';AccountContext='Machine';CaptureHost='fixture';PowerShellVersion='5.1';RequestedPortableRoots=@($portableRoot)};Entries=@($softwareEntry,$portableEntry);Coverage=@([pscustomobject][ordered]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='Registry';Count=1;Budget=[pscustomobject]@{MaxEntries=10};ErrorKind='';ObservedUtc=$now});PreparationRequirements=@([pscustomobject][ordered]@{PreparationId=('prep-'+$softwareId.Substring(3));SoftwareId=$softwareId;Status='NeedsOwnerReview';RequiredPhase='PreparationReady';EvidenceStatus='Success';ConsumerItemIds=@();Owner='';Reason=''},[pscustomobject][ordered]@{PreparationId=('prep-'+$portableId.Substring(3));SoftwareId=$portableId;Status='NeedsOwnerReview';RequiredPhase='PreparationReady';EvidenceStatus='Success';ConsumerItemIds=@();Owner='';Reason=''})}
    $softwareCatalog|Add-Member NoteProperty CatalogProjectionHash (& $module { param($c) Get-WsmSoftwareCatalogProjectionHash $c } $softwareCatalog)
    $scanInventory|Add-Member NoteProperty SoftwareCatalog $softwareCatalog -Force
    $scanHash=& $module { param($value) Get-WsmHashText ($value|ConvertTo-Json -Depth 30 -Compress) } $scanInventory
    $first=& $module { param($workspace,$profile,$inventory,$hash,$root) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root '' $null 3 10 } $scanWorkspace $scanProfile $scanInventory $scanHash $fixtureRoot
    Check ($first.Status -ceq 'ReviewRequired' -and $first.ContinuationRequired -and $first.ScanId) ('entry budget produces durable partial result with continuation ID (status='+$first.Status+' scanStatus='+$first.ScanStatus+' continue='+$first.ContinuationRequired+' scanId='+$first.ScanId+')')
    Check ([IO.File]::Exists($first.ReportPath) -and [IO.File]::Exists($first.CandidatePath)) 'partial candidate data and review HTML are written'
    $firstReport=[IO.File]::ReadAllText($first.ReportPath)
    Check ($firstReport.Contains('涵蓋缺口') -and $firstReport.Contains('尚未完成') -and $firstReport.Contains('探索識別碼（ScanId）') -and -not $firstReport.Contains('DO NOT READ THIS CONTENT')) 'review HTML presents Traditional Chinese status and coverage labels without file content'
    $scanLockPath=Join-Path (Split-Path $first.CandidatePath -Parent) 'scan.lock';$heldScanLock=[IO.File]::Open($scanLockPath,'OpenOrCreate','ReadWrite','None')
    try { ExpectFailure { & $module { param($workspace,$profile,$inventory,$hash,$root,$scanId) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root $scanId $null 3 10 } $scanWorkspace $scanProfile $scanInventory $scanHash $fixtureRoot $first.ScanId } 'same ScanId cannot be concurrently resumed from a second CLI or HTML process' } finally {$heldScanLock.Dispose()}
    $reportArtifacts=& $module { param($workspace,$path) Get-WsmHtmlReportArtifacts 'SourceCandidateScan' @([pscustomobject]@{ReportPath=$path}) $workspace } $scanWorkspace $first.ReportPath
    Check (@($reportArtifacts).Count -eq 1 -and $reportArtifacts[0].SHA256 -ceq $first.ReportHash -and $reportArtifacts[0].Path -ceq $first.ReportPath) 'HTML report link is allowlisted, source-workspace-contained and hash-bound'

    $checkpointPath=Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $scanWorkspace 'hosts') $scanProfile.Fingerprint) 'source-candidate-scans') $first.ScanId) 'checkpoint.json'
    $checkpointBytes=[IO.File]::ReadAllBytes($checkpointPath)
    $tampered=& $module { param($path) Read-WsmJson $path } $checkpointPath
    $tampered.Queue=@('C:\outside-volume')
    & $module { param($path,$data) Write-WsmJson $path $data } $checkpointPath $tampered
    ExpectFailure { & $module { param($workspace,$profile,$inventory,$hash,$root,$scanId) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root $scanId $null 3 10 } $scanWorkspace $scanProfile $scanInventory $scanHash $fixtureRoot $first.ScanId } 'malformed checkpoint cannot redirect the resumed scan outside its enrolled volume'
    [IO.File]::WriteAllBytes($checkpointPath,$checkpointBytes)

    $resumed=$first
    for($attempt=0;$attempt -lt 40 -and $resumed.ContinuationRequired;$attempt++){$resumed=& $module { param($workspace,$profile,$inventory,$hash,$root,$scanId) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root $scanId $null 3 10 } $scanWorkspace $scanProfile $scanInventory $scanHash $fixtureRoot $first.ScanId}
    Check ($resumed.ScanStatus -ceq 'Succeeded' -and -not $resumed.ContinuationRequired) 'same ScanId resumes durable frontier to a terminal bounded scan result'
    $candidateArtifact=Get-Content -LiteralPath $resumed.CandidatePath -Raw | ConvertFrom-Json
    Check (@($candidateArtifact.Candidates|Where-Object CandidateType -CEQ 'ExactFile'|Where-Object Path -IEQ (Join-Path $fixtureRoot 'loose root.txt')).Count -eq 1) 'root loose file appears as one exact-file candidate'
    Check (@($candidateArtifact.Candidates|Where-Object CandidateType -CEQ 'DirectoryRoot'|Where-Object Path -IEQ $business).Count -eq 1) 'unrelated business directory appears as a review candidate'
    Check (@($candidateArtifact.Candidates|Where-Object CandidateType -CEQ 'DirectoryRoot'|Where-Object Path -IEQ $programBusiness).Count -eq 1) 'ProgramData business directory remains discoverable as a candidate'
    Check (@($candidateArtifact.ExcludedAreas|Where-Object Path -IEQ $programCache).Count -eq 1 -and @($candidateArtifact.Candidates|Where-Object Path -Like ($programCache+'*')).Count -eq 0 -and @($candidateArtifact.ExcludedAreas|Where-Object Path -IEQ $programWindows).Count -eq 1 -and @($candidateArtifact.Candidates|Where-Object Path -Like ($programWindows+'*')).Count -eq 0) 'ProgramData package cache and Microsoft Windows state remain explicit protected exclusions'
    Check (@($candidateArtifact.ExcludedAreas|Where-Object Path -IEQ $customInstall).Count -eq 1 -and @($candidateArtifact.Candidates|Where-Object Path -Like ($customInstall+'*')).Count -eq 0 -and @($candidateArtifact.ExcludedAreas|Where-Object Path -IEQ $portableRoot).Count -eq 1 -and @($candidateArtifact.Candidates|Where-Object Path -Like ($portableRoot+'*')).Count -eq 0 -and $candidateArtifact.Coverage.SoftwareRootCoverageStatus -ceq 'Captured') 'trusted custom installed and requested Portable roots are excluded with captured coverage evidence'
    Check (@($candidateArtifact.ExcludedAreas|Where-Object Path -IEQ $scanWorkspace).Count -eq 1 -and @($candidateArtifact.Candidates|Where-Object Path -Like ($scanWorkspace+'*')).Count -eq 0) 'scan workspace output subtree is excluded from its own candidate input'
    Check (@($candidateArtifact.ExcludedAreas|Where-Object Path -IEQ $protected).Count -eq 1 -and @($candidateArtifact.Candidates|Where-Object Path -Like ($protected+'*')).Count -eq 0) 'protected Windows subtree is explicitly excluded and never traversed'
    $guardRootExclusions=@(foreach($name in $guardProtectedRoots){Join-Path $fixtureRoot $name})
    $guardFileExclusions=@(foreach($name in @('pagefile.sys','swapfile.sys','hiberfil.sys','bootmgr')){Join-Path $fixtureRoot $name})
    $guardProtectedCandidates=@($candidateArtifact.Candidates|Where-Object {$candidatePath=[string]$_.Path;@($guardRootExclusions|Where-Object {$candidatePath -ieq $_ -or $candidatePath.StartsWith($_.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)}).Count -gt 0})
    Check (@($guardRootExclusions|Where-Object {$candidateArtifact.ExcludedAreas.Path -contains $_}).Count -eq $guardRootExclusions.Count -and $guardProtectedCandidates.Count -eq 0) 'shared FileScope guard excludes Windows.old, Boot, WindowsImageBackup, WinSxS and ProgramW6432 roots and descendants'
    Check (@($guardFileExclusions|Where-Object {$candidateArtifact.ExcludedAreas.Path -contains $_}).Count -eq $guardFileExclusions.Count -and @($candidateArtifact.Candidates|Where-Object {$guardFileExclusions -contains $_.Path}).Count -eq 0) 'shared FileScope guard excludes root paging and boot files'
    Check (@($candidateArtifact.Candidates|Where-Object Path -IEQ (Join-Path $business 'business.exe')).Count -eq 1 -and @($candidateArtifact.Candidates|Where-Object Path -IEQ (Join-Path $business 'business.dll')).Count -eq 1) 'business executable and library files remain eligible candidates outside protected roots'
    Check ($candidateArtifact.AuthoritativeApproval -eq $false -and $candidateArtifact.ContentRead -eq $false -and @($candidateArtifact.Candidates|Where-Object {$_.PSObject.Properties['Content'] -or -not $_.MetadataOnly}).Count -eq 0) 'candidate artifact carries metadata only and grants no approval'
    Check ($candidateArtifact.Candidates[0].WorkloadReferenceCount -gt 0 -and @($candidateArtifact.Candidates[0].WorkloadReferences|Where-Object ConsumerItemId -CEQ $knownWorkloadItem.ItemId).Count -gt 0 -and $candidateArtifact.UnmatchedWorkloadReferences.Count -eq 0 -and $resumed.ReportPath) 'validated workload path reference is linked to and prioritizes its discovered candidate'
    Check ([IO.File]::ReadAllText($resumed.ReportPath).Contains($knownWorkloadItem.ItemId) -and [IO.File]::ReadAllText($resumed.ReportPath).Contains('已知工作負載參照')) 'review report shows known task references alongside prioritized candidates'
    Check ([string]$candidateArtifact.Coverage.Claim -like 'Bounded-policy coverage only*') 'terminal scan reports bounded-policy coverage without claiming whole-volume completeness'

    # Exercise the registered operation, its real source-job projection and HTML
    # cancellation binding while redirecting only the local root resolver to fixtures.
    & $module {
        param($root)
        $script:WsmSourceCandidateTestRoot=$root
        Set-Item -Path Function:\Get-WsmSourceCandidateRoot -Value { param([string]$Workspace,$Profile) $script:WsmSourceCandidateTestRoot }
    } $fixtureRoot
    $testRoot=& $module { param($workspace,$profile) Get-WsmSourceCandidateRoot $workspace $profile } $workspace $profile
    Check ($testRoot -ieq $fixtureRoot) 'registered operation fixture safely replaces only the enrolled-source root resolver'
    & $module {
        $script:WsmCliOriginalHtmlCancellation=(Get-Item Function:\New-WsmHtmlCancellation).ScriptBlock
        $script:WsmCliCapturedToken=$null
        Set-Item -Path Function:\New-WsmHtmlCancellation -Value {
            param($Command,$Arguments,[string]$OperationId,[object[]]$Jobs=@())
            $token=& $script:WsmCliOriginalHtmlCancellation $Command $Arguments $OperationId $Jobs
            $script:WsmCliCapturedToken=$token
            Request-WsmCancellation -Token $token -Owner 'SourceCandidateDiscoveryTest' -Evidence 'Fixture text CLI cancellation wiring' | Out-Null
            $token
        }
    }
    $script:textPromptValues=@('1','SourceCandidateScan','','no','APPLY');$script:textPromptIndex=0
    $textPromptReader={param($prompt)if($script:textPromptIndex -ge $script:textPromptValues.Count){throw ('Unexpected text prompt: '+$prompt)};$answer=$script:textPromptValues[$script:textPromptIndex];$script:textPromptIndex++;$answer}
    $storedTextInventoryJob=Get-Content -LiteralPath (Join-Path (Join-Path $workspace 'console-jobs') ($jobId+'.json')) -Raw | ConvertFrom-Json
    Check ($storedTextInventoryJob.action -ceq 'EnrolledInventory' -and $storedTextInventoryJob.status -ceq 'Succeeded' -and -not $storedTextInventoryJob.pairId) ('fixture source inventory job is stored as a valid unpaired text job: action='+$storedTextInventoryJob.action+' status='+$storedTextInventoryJob.status+' pairId='+$storedTextInventoryJob.pairId)
    $textConsumer=& $module { param($workspace,$reader) Invoke-WsmTypedTextOperation -Workspace $workspace -PromptReader $reader } $workspace $textPromptReader
    $textJobs=& $module { param($workspace) Get-WsmTextWizardJobs $workspace '' Source } $workspace
    $textScanJob=@($textJobs|Where-Object action -CEQ 'SourceCandidateScan'|Select-Object -First 1)
    $textScanRecord=Get-Content -LiteralPath (Join-Path (Join-Path $workspace 'console-jobs') ($textScanJob[0].jobId+'.json')) -Raw | ConvertFrom-Json
    $textToken=& $module { $script:WsmCliCapturedToken }
    $textCancellation=& $module { param($path) Read-WsmJson $path } $textToken.RequestPath
        Check ($textConsumer.Status -ceq 'Applied' -and $textScanJob.Count -eq 1 -and $textScanJob[0].status -ceq 'ReviewRequired') 'typed text CLI discovers source inventory, dispatches the registered scan, and stores its resumable job result'
    Check ($textCancellation.OperationId -ceq $textScanJob[0].jobId -and $textToken.OperationId -ceq $textScanJob[0].jobId -and $textScanRecord.operationId -ceq $textScanJob[0].jobId -and $textCancellation.PlanHash -ceq $inventoryHash -and $textToken.PlanHash -ceq $inventoryHash) 'typed CLI cancellation request, durable job and inventory-bound token share the same operation identity'
    $textProjectedOutput=@($textScanRecord.outputs)[0]
    Check ($textProjectedOutput.ScanId -and $textProjectedOutput.ContinuationRequired -and $textProjectedOutput.ContinuationScanId -ceq $textProjectedOutput.ScanId -and $textProjectedOutput.CandidatePath -and $textProjectedOutput.CandidateHash -match '^[a-f0-9]{64}$' -and $textProjectedOutput.SegmentNumber -ge 1 -and $textProjectedOutput.SegmentCount -ge 0 -and $textProjectedOutput.ExplicitContinuationRequired -is [bool]) 'durable text job preserves scan continuation ID, segment summary and hash-bound candidate artifact fields'
    $publicTextJob=& $module { param($record) ConvertTo-WsmHtmlPublicJobRecord $record } $textScanRecord
    Check ($publicTextJob.outputs[0].ScanId -ceq $textProjectedOutput.ScanId -and $publicTextJob.outputs[0].ContinuationScanId -ceq $textProjectedOutput.ContinuationScanId -and $publicTextJob.outputs[0].CandidatePath -ceq $textProjectedOutput.CandidatePath -and $publicTextJob.outputs[0].CandidateHash -ceq $textProjectedOutput.CandidateHash -and $publicTextJob.outputs[0].SegmentNumber -eq $textProjectedOutput.SegmentNumber -and $publicTextJob.outputs[0].SegmentCount -eq $textProjectedOutput.SegmentCount -and $publicTextJob.outputs[0].ExplicitContinuationRequired -eq $textProjectedOutput.ExplicitContinuationRequired) 'HTML durable-job projection exposes continuation and bounded-segment summary fields'
    $originalHtmlCancellation=& $module { $script:WsmCliOriginalHtmlCancellation }
    & $module { param($original) Set-Item -Path Function:\New-WsmHtmlCancellation -Value $original } $originalHtmlCancellation
    $htmlJobs=@{$jobId=[pscustomobject]@{Record=$job}}
    $sourceJobs=& $module { param($jobs,$workspace) Get-WsmHtmlWizardJobs $jobs $workspace } $htmlJobs $workspace
    Check (@($sourceJobs).Count -eq 1 -and $sourceJobs[0].jobId -ceq $jobId) 'HTML job projection injects the verified source inventory record into operation dispatch'
    $actionMap=& $module { Get-WsmHtmlActionMap }
    $registeredCommand=Get-Command $actionMap.SourceCandidateScan -ErrorAction Stop
    $consumerOperation=[Guid]::NewGuid().ToString('D')
    $consumerResult=& $registeredCommand -Workspace $workspace -Jobs $sourceJobs -OperationId $consumerOperation
    $consumerArtifact=Get-Content -LiteralPath $consumerResult.CandidatePath -Raw | ConvertFrom-Json
    Check ($consumerResult.Status -ceq 'Succeeded' -and @($consumerArtifact.Candidates|Where-Object Path -IEQ $business).Count -eq 1 -and [IO.File]::Exists($consumerResult.ReportPath)) 'registered source candidate operation consumes bound inventory and emits fixture candidates plus review report'
    $htmlProjectedOutput=& $module { param($output) @(Get-WsmHtmlResultProjection $output)[0] } $consumerResult
    Check ($htmlProjectedOutput.ScanId -ceq $consumerResult.ScanId -and $htmlProjectedOutput.CandidatePath -ceq $consumerResult.CandidatePath -and $htmlProjectedOutput.CandidateHash -ceq $consumerResult.CandidateHash -and $htmlProjectedOutput.ContinuationRequired -eq $consumerResult.ContinuationRequired -and $htmlProjectedOutput.SegmentNumber -eq $consumerResult.SegmentNumber -and $htmlProjectedOutput.SegmentCount -eq $consumerResult.SegmentCount -and $htmlProjectedOutput.ExplicitContinuationRequired -eq $consumerResult.ExplicitContinuationRequired) 'HTML result projection retains only the candidate scan continuation, integrity and segment summary fields'
    $cancelOperation=[Guid]::NewGuid().ToString('D')
    $cancelArguments=@{Workspace=$workspace;ScanId=''}
    $htmlToken=& $module { param($command,$arguments,$operationId,$jobs) New-WsmHtmlCancellation $command $arguments $operationId $jobs } $registeredCommand $cancelArguments $cancelOperation $sourceJobs
    Check ($htmlToken -and $htmlToken.OperationId -ceq $cancelOperation -and $htmlToken.PlanHash -ceq $inventoryHash) 'HTML cancellation token binds the registered source operation to its verified inventory and operation ID'
    $null=Request-WsmCancellation -Token $htmlToken -Owner 'SourceCandidateDiscoveryTest' -Evidence 'Fixture HTML cancellation wiring'
    $cancelResult=& $registeredCommand -Workspace $workspace -Jobs $sourceJobs -OperationId $cancelOperation -CancellationToken $htmlToken
    $htmlCancelArtifact=Get-Content -LiteralPath $cancelResult.CandidatePath -Raw | ConvertFrom-Json
    Check ($cancelResult.ContinuationRequired -and @($htmlCancelArtifact.Gaps|Where-Object Reason -CEQ 'CancelledAtSafeBoundary').Count -eq 1 -and [IO.File]::Exists($cancelResult.ReportPath)) 'registered operation observes HTML cancellation token and publishes a resumable review report'

    $originalCore=& $module { (Get-Item Function:\Invoke-WsmSourceCandidateScanCore).ScriptBlock }
    & $module { Set-Item Function:\Invoke-WsmSourceCandidateScanCore -Value { param([string]$Workspace,$Profile,$Inventory,[string]$InventoryHash,[string]$SourceRoot,[string]$ScanId='',[object]$CancellationToken=$null,[int]$MaxEntries=4000,[int]$MaxSeconds=25,[int]$MaxTotalEntries=50000,[scriptblock]$CancellationTestHook=$null,[scriptblock]$ReplayTestHook=$null,[long]$MaxAggregatePathBytes=4194304,[switch]$ContinueAfterBudgetExhausted) $script:WsmTextContinuationCapture=[pscustomobject]@{ScanId=$ScanId;Continue=[bool]$ContinueAfterBudgetExhausted;MaxTotalEntries=$MaxTotalEntries};[pscustomobject]@{Status='ReviewRequired';ScanId=$ScanId;ScanStatus='BudgetExhausted';ContinuationRequired=$true;ContinuationScanId=$ScanId;ExplicitContinuationRequired=$true;SegmentNumber=2;SegmentCount=2;CandidateCount=0;ScannedEntryCount=50000;GapCount=1;CandidatePath='fixture-candidates.json';CandidateHash=('a'*64);ReportPath='fixture-review.html';ReportHash=('b'*64);AuthoritativeApproval=$false;ContentRead=$false} } }
    try {
        $script:textPromptValues=@('1','SourceCandidateScan',$consumerResult.ScanId,'yes','APPLY');$script:textPromptIndex=0
        $textContinue=& $module { param($workspace,$reader) Invoke-WsmTypedTextOperation -Workspace $workspace -PromptReader $reader } $workspace $textPromptReader
        $textContinueCapture=& $module { $script:WsmTextContinuationCapture }
        Check ($textContinue.Status -ceq 'Applied' -and $textContinueCapture.Continue -and $textContinueCapture.ScanId -ceq $consumerResult.ScanId -and $textContinueCapture.MaxTotalEntries -eq 5000) 'typed CLI dispatches explicit continuation with its fixed production segment budget'
    } finally { & $module { param($original) Set-Item Function:\Invoke-WsmSourceCandidateScanCore -Value $original } $originalCore }

    $noCatalogInventory=& $module { param($source) New-WsmInventory $source 1 @() } $scanSource
    $noCatalogHash=& $module { param($value) Get-WsmHashText ($value|ConvertTo-Json -Depth 30 -Compress) } $noCatalogInventory
    $noCatalog=& $module { param($workspace,$profile,$inventory,$hash,$root) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root '' $null 1 10 } $scanWorkspace $scanProfile $noCatalogInventory $noCatalogHash $fixtureRoot
    $noCatalogArtifact=Get-Content -LiteralPath $noCatalog.CandidatePath -Raw | ConvertFrom-Json
    Check ($noCatalogArtifact.Coverage.SoftwareRootCoverageStatus -ceq 'Unavailable' -and @($noCatalogArtifact.Coverage.SoftwareRootCoverageGaps).Count -gt 0 -and $noCatalog.ReportPath) 'missing SoftwareCatalog is disclosed as incomplete installed-software root coverage in review output'

    # A persisted queue can be attacked by replacing an ancestor after the first run.
    $resumeParent=Join-Path $fixtureRoot 'resume-parent';$resumeChild=Join-Path $resumeParent 'child';$outside=Join-Path $tempRoot 'outside';[void][IO.Directory]::CreateDirectory($resumeChild);[void][IO.Directory]::CreateDirectory($outside)
    $outsideMarker=Join-Path $outside 'must-not-be-seen.txt';[IO.File]::WriteAllText($outsideMarker,'outside')
    $junctionStart=& $module { param($workspace,$profile,$inventory,$hash,$root) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root '' $null 1 10 } $scanWorkspace $scanProfile $scanInventory $scanHash $fixtureRoot
    $junctionCheckpointPath=Join-Path (Split-Path $junctionStart.CandidatePath -Parent) 'checkpoint.json';$junctionCheckpoint=& $module { param($path) Read-WsmJson $path } $junctionCheckpointPath
    $junctionCheckpoint.Status='Partial';$junctionCheckpoint.Queue=@($resumeChild);$junctionCheckpoint.CurrentDirectory='';$junctionCheckpoint.CurrentDirectoryWriteUtc='';$junctionCheckpoint.CurrentDirectorySeen=@()
    & $module { param($path,$data) Write-WsmJson $path $data } $junctionCheckpointPath $junctionCheckpoint
    Remove-Item -LiteralPath $resumeParent -Recurse -Force
    New-Item -ItemType Junction -Path $resumeParent -Target $outside | Out-Null
    $junctionResume=& $module { param($workspace,$profile,$inventory,$hash,$root,$scanId) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root $scanId $null 10 10 } $scanWorkspace $scanProfile $scanInventory $scanHash $fixtureRoot $junctionStart.ScanId
    $junctionArtifact=Get-Content -LiteralPath $junctionResume.CandidatePath -Raw | ConvertFrom-Json
    Check (@($junctionArtifact.Gaps|Where-Object {$_.Path -ieq $resumeChild -and $_.Reason -ceq 'ReparsePointNotFollowed'}).Count -eq 1 -and @($junctionArtifact.Candidates|Where-Object Path -IEQ $outsideMarker).Count -eq 0) 'resume rejects a queued directory whose ancestor was replaced by a junction and never scans its target'

    $missingParent=Join-Path $fixtureRoot 'resume-missing';$missingChild=Join-Path $missingParent 'child';[void][IO.Directory]::CreateDirectory($missingChild)
    $missingStart=& $module { param($workspace,$profile,$inventory,$hash,$root) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root '' $null 1 10 } $scanWorkspace $scanProfile $scanInventory $scanHash $fixtureRoot
    $missingCheckpointPath=Join-Path (Split-Path $missingStart.CandidatePath -Parent) 'checkpoint.json';$missingCheckpoint=& $module { param($path) Read-WsmJson $path } $missingCheckpointPath
    $missingCheckpoint.Status='Partial';$missingCheckpoint.Queue=@($missingChild);$missingCheckpoint.CurrentDirectory='';$missingCheckpoint.CurrentDirectoryWriteUtc='';$missingCheckpoint.CurrentDirectorySeen=@()
    & $module { param($path,$data) Write-WsmJson $path $data } $missingCheckpointPath $missingCheckpoint
    Remove-Item -LiteralPath $missingParent -Recurse -Force
    $missingResume=& $module { param($workspace,$profile,$inventory,$hash,$root,$scanId) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root $scanId $null 10 10 } $scanWorkspace $scanProfile $scanInventory $scanHash $fixtureRoot $missingStart.ScanId
    $missingArtifact=Get-Content -LiteralPath $missingResume.CandidatePath -Raw | ConvertFrom-Json
    Check (@($missingArtifact.Gaps|Where-Object {$_.Path -ieq $missingChild -and $_.Reason -ceq 'DirectoryUnavailable'}).Count -eq 1 -and $missingResume.ScanStatus -ceq 'Succeeded') 'missing queued directory becomes a durable coverage gap and does not abort the scan'

    $stale=& $module { param($workspace,$profile,$inventory,$hash,$root) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root '' $null 1 10 } $scanWorkspace $scanProfile $scanInventory $scanHash $fixtureRoot
    ExpectFailure { & $module { param($workspace,$profile,$inventory,$hash,$root,$scanId) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory ('b'*64) $root $scanId $null 1 10 } $scanWorkspace $scanProfile $scanInventory $scanHash $fixtureRoot $stale.ScanId } 'resume rejects a changed source inventory hash'

    $capped=& $module { param($workspace,$profile,$inventory,$hash,$root) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root '' $null 4000 10 2 } $scanWorkspace $scanProfile $scanInventory $scanHash $fixtureRoot
    $capArtifact=Get-Content -LiteralPath $capped.CandidatePath -Raw | ConvertFrom-Json
    Check ($capped.ScannedEntryCount -le 2 -and $capped.ScanStatus -ceq 'BudgetExhausted' -and @($capArtifact.Gaps|Where-Object Reason -CEQ 'CumulativeEntryBudgetExceeded').Count -eq 1) 'cumulative entry cap stops at its fixed maximum and records a durable coverage gap'
    $capReport=[IO.File]::ReadAllText($capped.ReportPath)
    Check ($capReport.Contains('本掃描分段已達項目數上限') -and $capReport.Contains('明確啟動下一個有界分段') -and $capReport.Contains('剩餘路徑')) 'budget-exhausted report offers only explicit bounded continuation and keeps remaining paths visible'
    ExpectFailure { & $module { param($workspace,$profile,$inventory,$hash,$root,$scanId) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root $scanId $null 10 10 2 } $scanWorkspace $scanProfile $scanInventory $scanHash $fixtureRoot $capped.ScanId } 'cumulative-budget checkpoint is terminal and cannot silently resume or reset'

    $segmentRoot=Join-Path $tempRoot 'segment-fixture';[void][IO.Directory]::CreateDirectory($segmentRoot);$expectedSegmentFiles=@('alpha.dat','beta.dat','gamma.dat');foreach($name in $expectedSegmentFiles){[IO.File]::WriteAllText((Join-Path $segmentRoot $name),$name)}
    $segmentInventory=& $module { param($source) New-WsmInventory $source 1 @() } $scanSource;$segmentHash=& $module { param($value) Get-WsmHashText ($value|ConvertTo-Json -Depth 30 -Compress) } $segmentInventory
    $segmentOne=& $module { param($workspace,$profile,$inventory,$hash,$root) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root '' $null 4000 10 2 } $scanWorkspace $scanProfile $segmentInventory $segmentHash $segmentRoot
    $segmentOneArtifact=Get-Content -LiteralPath $segmentOne.CandidatePath -Raw|ConvertFrom-Json
    Check ($segmentOne.ScanStatus -ceq 'BudgetExhausted' -and $segmentOne.ContinuationRequired -and $segmentOne.ExplicitContinuationRequired -and $segmentOneArtifact.Segments.Count -eq 1) 'entry cap freezes the first immutable segment and requires explicit continuation'
    $segmentOnePath=Join-Path (Split-Path $segmentOne.CandidatePath -Parent) 'segments\segment-001.json';$segmentOneHash=(Get-FileHash -LiteralPath $segmentOnePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $segmentTwo=& $module { param($workspace,$profile,$inventory,$hash,$root,$scanId) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root $scanId $null 4000 10 2 $null -ContinueAfterBudgetExhausted } $scanWorkspace $scanProfile $segmentInventory $segmentHash $segmentRoot $segmentOne.ScanId
    $segmentTwoArtifact=Get-Content -LiteralPath $segmentTwo.CandidatePath -Raw|ConvertFrom-Json;$segmentTwoCheckpoint=Get-Content -LiteralPath (Join-Path (Split-Path $segmentTwo.CandidatePath -Parent) 'checkpoint.json') -Raw|ConvertFrom-Json
    $actualSegmentPaths=@($segmentTwoArtifact.Candidates|ForEach-Object {[IO.Path]::GetFileName([string]$_.Path)}|Sort-Object)
    Check ($segmentTwo.ScanStatus -ceq 'Succeeded' -and $segmentTwoArtifact.Segments.Count -eq 2 -and $segmentTwoCheckpoint.Segments[0].SHA256 -ceq $segmentOneHash -and (Get-FileHash -LiteralPath $segmentOnePath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $segmentOneHash) 'second segment continues the exact saved frontier and keeps the first hash-bound artifact immutable'
    Check (($actualSegmentPaths -join ',') -ceq (($expectedSegmentFiles|Sort-Object)-join ',') -and $segmentTwo.CandidateCount -eq 3 -and @($segmentTwoArtifact.Gaps|Where-Object Reason -CEQ 'CumulativeEntryBudgetExceeded').Count -eq 1) 'two bounded segments have exact candidate membership and preserve the first segment coverage gap'
    Check ($segmentTwoArtifact.Coverage.ScannedEntries -eq 3 -and $segmentTwoArtifact.Coverage.MaxAggregateEntries -eq 40000 -and $segmentTwoArtifact.Coverage.MaxAggregatePathBytes -eq 4194304 -and $segmentTwoArtifact.Coverage.MaxWorkloadReferenceCount -eq 10000 -and $segmentTwoArtifact.Coverage.MaxWorkloadReferenceBytes -eq 2097152 -and $segmentTwoArtifact.Coverage.SegmentLimit -eq 8) ('continued output reports JSON-safe entry, path and workload-reference budgets with the segment ceiling (entries='+$segmentTwoArtifact.Coverage.MaxAggregateEntries+' pathBytes='+$segmentTwoArtifact.Coverage.MaxAggregatePathBytes+' refs='+$segmentTwoArtifact.Coverage.MaxWorkloadReferenceCount+' refBytes='+$segmentTwoArtifact.Coverage.MaxWorkloadReferenceBytes+' segments='+$segmentTwoArtifact.Coverage.SegmentLimit+')')

    $aggregateBoundaryRoot=Join-Path $tempRoot 'aggregate-boundary-root';[void][IO.Directory]::CreateDirectory($aggregateBoundaryRoot);foreach($name in @('one.dat','two.dat')){[IO.File]::WriteAllText((Join-Path $aggregateBoundaryRoot $name),$name)}
    $aggregateBoundary=& $module { param($workspace,$profile,$inventory,$hash,$root) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root '' $null 4000 10 1 $null $null 4194304 -MaxAggregateEntries 1 } $scanWorkspace $scanProfile $segmentInventory $segmentHash $aggregateBoundaryRoot
    $aggregateBoundaryArtifact=Get-Content -LiteralPath $aggregateBoundary.CandidatePath -Raw|ConvertFrom-Json
    $aggregateBoundaryReport=[IO.File]::ReadAllText($aggregateBoundary.ReportPath)
    Check ($aggregateBoundary.ScanStatus -ceq 'BudgetExhausted' -and $aggregateBoundary.ScannedEntryCount -eq 1 -and $aggregateBoundaryArtifact.Coverage.MaxAggregateEntries -eq 1 -and -not $aggregateBoundary.ContinuationRequired -and -not $aggregateBoundary.ExplicitContinuationRequired -and $aggregateBoundaryReport.Contains('已達總中繼資料項目上限') -and $aggregateBoundaryReport.Contains('剩餘路徑須另行補查')) 'aggregate ceiling suppresses a futile next segment and reports remaining paths for separate review'
    ExpectFailure { & $module { param($workspace,$profile,$inventory,$hash,$root,$scanId) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root $scanId $null 4000 10 1 $null $null 4194304 -ContinueAfterBudgetExhausted -MaxAggregateEntries 1 } $scanWorkspace $scanProfile $segmentInventory $segmentHash $aggregateBoundaryRoot $aggregateBoundary.ScanId } 'aggregate-ceiling checkpoint rejects a no-work continuation request'

    $orphanRoot=Join-Path $tempRoot 'orphan-segment-root';[void][IO.Directory]::CreateDirectory($orphanRoot);foreach($name in @('one.dat','two.dat','three.dat')){[IO.File]::WriteAllText((Join-Path $orphanRoot $name),$name)}
    $orphanOne=& $module { param($workspace,$profile,$inventory,$hash,$root) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root '' $null 4000 10 2 } $scanWorkspace $scanProfile $segmentInventory $segmentHash $orphanRoot
    $orphanScanDirectory=Split-Path $orphanOne.CandidatePath -Parent;$orphanCheckpointPath=Join-Path $orphanScanDirectory 'checkpoint.json';$orphanSegmentPath=Join-Path $orphanScanDirectory 'segments\segment-001.json';$orphanSegmentHash=(Get-FileHash -LiteralPath $orphanSegmentPath -Algorithm SHA256).Hash.ToLowerInvariant();$orphanCheckpoint=& $module { param($path) Read-WsmJson $path } $orphanCheckpointPath
    $orphanFrontierTimestamp=[string]$orphanCheckpoint.CurrentDirectoryWriteUtc
    Check ($orphanCheckpoint.CurrentDirectoryWriteUtc -is [string]) 'production checkpoint reader preserves the directory timestamp as an exact string before test mutation'
    $orphanCheckpoint.Segments=@();& $module { param($path,$data) Write-WsmJson $path $data } $orphanCheckpointPath $orphanCheckpoint
    $orphanRoundTrip=& $module { param($path) Read-WsmJson $path } $orphanCheckpointPath
    Check ([string]$orphanRoundTrip.CurrentDirectoryWriteUtc -ceq $orphanFrontierTimestamp) 'orphan test mutation preserves exact checkpoint frontier timestamp text'
    $orphanResumed=& $module { param($workspace,$profile,$inventory,$hash,$root,$scanId) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root $scanId $null 4000 10 2 $null -ContinueAfterBudgetExhausted } $scanWorkspace $scanProfile $segmentInventory $segmentHash $orphanRoot $orphanOne.ScanId
    $orphanArtifact=Get-Content -LiteralPath $orphanResumed.CandidatePath -Raw|ConvertFrom-Json
    Check ($orphanResumed.ScanStatus -ceq 'Succeeded' -and $orphanArtifact.Segments.Count -eq 2 -and $orphanArtifact.Segments[0].SHA256 -ceq $orphanSegmentHash -and (Get-FileHash -LiteralPath $orphanSegmentPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $orphanSegmentHash -and $orphanResumed.CandidateCount -eq 3) 'resume adopts a deterministic immutable segment left before its checkpoint descriptor was persisted, then continues without rewriting it'

    $legacyRoot=Join-Path $tempRoot 'legacy-checkpoint-root';[void][IO.Directory]::CreateDirectory($legacyRoot);foreach($name in @('a.dat','b.dat','c.dat')){[IO.File]::WriteAllText((Join-Path $legacyRoot $name),$name)}
    $legacyInventoryPath=Join-Path (Join-Path (Join-Path (Join-Path $scanWorkspace 'hosts') $scanProfile.Fingerprint) 'inventory') 'inventory-1.json'
    & $module { param($path,$data) Write-WsmJson $path $data } $legacyInventoryPath $segmentInventory
    $legacyInventoryFileHash=(Get-FileHash -LiteralPath $legacyInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant();$legacyJobId=[Guid]::NewGuid().ToString('D')
    $legacyJob=[pscustomobject]@{jobId=$legacyJobId;action='SourceInventory';role='Source';workspace=$scanWorkspace;status='Succeeded';outputs=@([pscustomobject]@{Path=$legacyInventoryPath;SHA256=$legacyInventoryFileHash})}
    $legacyStart=& $module { param($workspace,$profile,$inventory,$hash,$root) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root '' $null 1 10 50000 } $scanWorkspace $scanProfile $segmentInventory $legacyInventoryFileHash $legacyRoot
    $legacyCheckpointPath=Join-Path (Split-Path $legacyStart.CandidatePath -Parent) 'checkpoint.json';$legacyCheckpoint=& $module { param($path) Read-WsmJson $path } $legacyCheckpointPath
    foreach($property in @('SegmentNumber','SegmentEntryCount','Segments','SegmentStartCandidateCount','SegmentStartGapCount','SegmentStartExcludedCount','SegmentStartVisitedCount','LegacyBaselineEntryCount')){[void]$legacyCheckpoint.PSObject.Properties.Remove($property)}
    $legacyPolicyHash=& $module { param($root,$inventory,$workspace) $policy=Get-WsmSourceCandidatePolicy $root $inventory $workspace;$policy.PolicyVersion=1;$policy|Add-Member NoteProperty MaxTotalEntries 50000;$value=$policy|Select-Object * -ExcludeProperty PolicyHash,MaxSegments,MaxAggregateEntries,MaxAggregatePathBytes,MaxWorkloadReferenceCount,MaxWorkloadReferenceBytes;Get-WsmHashText ($value|ConvertTo-Json -Depth 8 -Compress) } $legacyRoot $segmentInventory $scanWorkspace
    $legacyCheckpoint.PolicyVersion=1;$legacyCheckpoint.PolicyHash=$legacyPolicyHash
    & $module { param($path,$data) Write-WsmJson $path $data } $legacyCheckpointPath $legacyCheckpoint
    & $module { param($root) $script:WsmSourceCandidateTestRoot=$root } $legacyRoot
    $null=Set-WsmWizardInventoryBinding -Workspace $scanWorkspace -Role Source -JobId $legacyJobId -ExpectedWizardRevision 0 -Jobs @($legacyJob)
    $legacyResume=Invoke-WsmSourceCandidateScan -Workspace $scanWorkspace -ScanId $legacyStart.ScanId -Jobs @($legacyJob)
    $migratedLegacyCheckpoint=Get-Content -LiteralPath $legacyCheckpointPath -Raw|ConvertFrom-Json
    Check ($legacyResume.ScanStatus -ceq 'Succeeded' -and $legacyResume.CandidateCount -eq 3 -and $migratedLegacyCheckpoint.PolicyVersion -eq 2 -and $migratedLegacyCheckpoint.LegacyBaselineEntryCount -eq 1) ('baseline D1 checkpoint shape migrates through the public production command, preserving its one-entry scanned baseline (status='+$legacyResume.ScanStatus+' candidates='+$legacyResume.CandidateCount+' gaps='+$legacyResume.GapCount+')')

    $metadataBudgetRoot=Join-Path $tempRoot 'metadata-budget-root';[void][IO.Directory]::CreateDirectory($metadataBudgetRoot);[IO.File]::WriteAllText((Join-Path $metadataBudgetRoot 'one.dat'),'fixture')
    $metadataBudget=& $module { param($workspace,$profile,$inventory,$hash,$root) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root '' $null 10 10 50000 $null $null 1 } $scanWorkspace $scanProfile $segmentInventory $segmentHash $metadataBudgetRoot
    $metadataBudgetArtifact=Get-Content -LiteralPath $metadataBudget.CandidatePath -Raw|ConvertFrom-Json
    Check ($metadataBudget.ScanStatus -ceq 'MetadataBudgetExceeded' -and -not $metadataBudget.ContinuationRequired -and $metadataBudgetArtifact.Coverage.MaxAggregatePathBytes -eq 1 -and @($metadataBudgetArtifact.Gaps|Where-Object Reason -CEQ 'MetadataBudgetExceeded').Count -eq 1 -and $metadataBudget.ScannedEntryCount -eq 0) 'injected tiny path budget stops before consuming the next entry and saves a terminal gap before the JSON limit'
    ExpectFailure { & $module { param($workspace,$profile,$inventory,$hash,$root,$scanId) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root $scanId $null 10 10 50000 } $scanWorkspace $scanProfile $segmentInventory $segmentHash $metadataBudgetRoot $metadataBudget.ScanId } 'metadata-budget checkpoint cannot be resumed into an oversized checkpoint'

    $staleRoot=Join-Path $tempRoot 'stale-root';[void][IO.Directory]::CreateDirectory($staleRoot);foreach($name in @('a.dat','b.dat','c.dat')){[IO.File]::WriteAllText((Join-Path $staleRoot $name),$name)}
    $staleRootStart=& $module { param($workspace,$profile,$inventory,$hash,$root) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root '' $null 4000 10 2 } $scanWorkspace $scanProfile $segmentInventory $segmentHash $staleRoot
    ExpectFailure { & $module { param($workspace,$profile,$inventory,$hash,$root,$scanId) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root $scanId $null 4000 10 2 $null -ContinueAfterBudgetExhausted } $scanWorkspace $scanProfile $segmentInventory $segmentHash $segmentRoot $staleRootStart.ScanId } 'explicit continuation rejects a changed physical root and policy binding'

    $frontierRoot=Join-Path $tempRoot 'frontier-tamper-root';[void][IO.Directory]::CreateDirectory($frontierRoot);foreach($name in @('a.dat','b.dat','c.dat')){[IO.File]::WriteAllText((Join-Path $frontierRoot $name),$name)}
    $frontierStart=& $module { param($workspace,$profile,$inventory,$hash,$root) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root '' $null 4000 10 2 } $scanWorkspace $scanProfile $segmentInventory $segmentHash $frontierRoot
    $frontierCheckpointPath=Join-Path (Split-Path $frontierStart.CandidatePath -Parent) 'checkpoint.json';$frontierCheckpoint=& $module { param($path) Read-WsmJson $path } $frontierCheckpointPath;$frontierCheckpoint.CurrentDirectorySeen=@($frontierCheckpoint.CurrentDirectorySeen|Select-Object -First 1);& $module { param($path,$data) Write-WsmJson $path $data } $frontierCheckpointPath $frontierCheckpoint
    ExpectFailure { & $module { param($workspace,$profile,$inventory,$hash,$root,$scanId) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root $scanId $null 4000 10 2 $null -ContinueAfterBudgetExhausted } $scanWorkspace $scanProfile $segmentInventory $segmentHash $frontierRoot $frontierStart.ScanId } 'continuation rejects a checkpoint whose seen cursor differs from the immutable segment frontier'

    $tamperRoot=Join-Path $tempRoot 'tamper-root';[void][IO.Directory]::CreateDirectory($tamperRoot);foreach($name in @('a.dat','b.dat','c.dat','d.dat','e.dat')){[IO.File]::WriteAllText((Join-Path $tamperRoot $name),$name)}
    $tamperOne=& $module { param($workspace,$profile,$inventory,$hash,$root) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root '' $null 4000 10 2 } $scanWorkspace $scanProfile $segmentInventory $segmentHash $tamperRoot
    $tamperTwo=& $module { param($workspace,$profile,$inventory,$hash,$root,$scanId) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root $scanId $null 4000 10 2 $null -ContinueAfterBudgetExhausted } $scanWorkspace $scanProfile $segmentInventory $segmentHash $tamperRoot $tamperOne.ScanId
    $tamperSegmentPath=Join-Path (Split-Path $tamperTwo.CandidatePath -Parent) 'segments\segment-001.json';[IO.File]::AppendAllText($tamperSegmentPath,'tampered')
    ExpectFailure { & $module { param($workspace,$profile,$inventory,$hash,$root,$scanId) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root $scanId $null 4000 10 2 $null -ContinueAfterBudgetExhausted } $scanWorkspace $scanProfile $segmentInventory $segmentHash $tamperRoot $tamperOne.ScanId } 'continuation rejects a tampered earlier segment instead of trusting a broken chain'

    $reparseRoot=Join-Path $tempRoot 'continuation-reparse-root';$reparseChild=Join-Path $reparseRoot 'child';$reparseOutside=Join-Path $tempRoot 'continuation-outside';[void][IO.Directory]::CreateDirectory($reparseChild);[void][IO.Directory]::CreateDirectory($reparseOutside);$reparseMarker=Join-Path $reparseOutside 'outside.dat';[IO.File]::WriteAllText($reparseMarker,'outside')
    $reparseOne=& $module { param($workspace,$profile,$inventory,$hash,$root) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root '' $null 4000 10 1 } $scanWorkspace $scanProfile $segmentInventory $segmentHash $reparseRoot
    Remove-Item -LiteralPath $reparseChild -Recurse -Force;New-Item -ItemType Junction -Path $reparseChild -Target $reparseOutside|Out-Null
    $reparseTwo=& $module { param($workspace,$profile,$inventory,$hash,$root,$scanId) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root $scanId $null 4000 10 1 $null -ContinueAfterBudgetExhausted } $scanWorkspace $scanProfile $segmentInventory $segmentHash $reparseRoot $reparseOne.ScanId
    $reparseArtifact=Get-Content -LiteralPath $reparseTwo.CandidatePath -Raw|ConvertFrom-Json
    Check (@($reparseArtifact.Gaps|Where-Object {$_.Path -ieq $reparseChild -and $_.Reason -ceq 'ReparsePointNotFollowed'}).Count -eq 1 -and @($reparseArtifact.Candidates|Where-Object Path -IEQ $reparseMarker).Count -eq 0) 'continued scan revalidates queued physical paths and rejects a directory replaced by a junction'

    $cancelSegmentRoot=Join-Path $tempRoot 'continuation-cancel-root';[void][IO.Directory]::CreateDirectory($cancelSegmentRoot);foreach($name in @('a.dat','b.dat','c.dat')){[IO.File]::WriteAllText((Join-Path $cancelSegmentRoot $name),$name)}
    $cancelSegmentOne=& $module { param($workspace,$profile,$inventory,$hash,$root) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root '' $null 4000 10 2 } $scanWorkspace $scanProfile $segmentInventory $segmentHash $cancelSegmentRoot
    $segmentCancelId=[Guid]::NewGuid().ToString('D');$segmentCancelToken=New-WsmCancellationToken -StateDirectory (Join-Path $scanWorkspace 'hosts') -PairId $scanProfile.HostId -PlanHash $segmentHash -OperationId $segmentCancelId;$null=Request-WsmCancellation -Token $segmentCancelToken -Owner 'SourceCandidateDiscoveryTest' -Evidence 'Cancel explicit fixture continuation'
    $cancelSegmentTwo=& $module { param($workspace,$profile,$inventory,$hash,$root,$scanId,$token) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root $scanId $token 4000 10 2 $null -ContinueAfterBudgetExhausted } $scanWorkspace $scanProfile $segmentInventory $segmentHash $cancelSegmentRoot $cancelSegmentOne.ScanId $segmentCancelToken
    $cancelSegmentArtifact=Get-Content -LiteralPath $cancelSegmentTwo.CandidatePath -Raw|ConvertFrom-Json
    Check ($cancelSegmentTwo.ScanStatus -ceq 'Partial' -and @($cancelSegmentArtifact.Segments).Count -eq 1 -and @($cancelSegmentArtifact.Gaps|Where-Object Reason -CEQ 'CancelledAtSafeBoundary').Count -eq 1 -and $cancelSegmentTwo.ContinuationScanId -ceq $cancelSegmentOne.ScanId) 'cancelled explicit continuation retains prior segment and a durable resumable gap'

    $cancelId=[Guid]::NewGuid().ToString('D');$cancelToken=New-WsmCancellationToken -StateDirectory (Join-Path $scanWorkspace 'hosts') -PairId $scanProfile.HostId -PlanHash $scanHash -OperationId $cancelId
    $cancelled=& $module { param($workspace,$profile,$inventory,$hash,$root,$token,$hook) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root '' $token 3 10 50000 $hook } $scanWorkspace $scanProfile $scanInventory $scanHash $fixtureRoot $cancelToken ({param($checkpoint,$token)if([long]$checkpoint.ScannedEntryCount -ge 1){$null=Request-WsmCancellation -Token $token -Owner 'SourceCandidateDiscoveryTest' -Evidence 'Fixture cancellation after first enumerated child'}})
    $cancelArtifact=Get-Content -LiteralPath $cancelled.CandidatePath -Raw | ConvertFrom-Json
    $cancelCheckpoint=Get-Content -LiteralPath (Join-Path (Split-Path $cancelled.CandidatePath -Parent) 'checkpoint.json') -Raw | ConvertFrom-Json
    Check ($cancelled.Status -ceq 'ReviewRequired' -and $cancelled.ContinuationRequired -and @($cancelArtifact.Gaps|Where-Object Reason -CEQ 'CancelledAtSafeBoundary').Count -eq 1) 'cancellation stops at a durable boundary and preserves a resumable partial checkpoint'
    Check ($cancelCheckpoint.CurrentDirectory -and @($cancelCheckpoint.CurrentDirectorySeen).Count -eq 1 -and @($cancelCheckpoint.VisitedDirectories|Where-Object {$_ -ieq $fixtureRoot}).Count -eq 0 -and $cancelArtifact.Coverage.RemainingDirectoryPaths -contains $cancelCheckpoint.CurrentDirectory) 'mid-directory cancellation retains its exact seen cursor and visibly lists the remaining directory path'

    $replayRoot=Join-Path $tempRoot 'replay-budget-root';[void][IO.Directory]::CreateDirectory($replayRoot);foreach($name in @('a.dat','b.dat','c.dat')){[IO.File]::WriteAllText((Join-Path $replayRoot $name),$name)}
    $replayCancelId=[Guid]::NewGuid().ToString('D');$replayToken=New-WsmCancellationToken -StateDirectory (Join-Path $scanWorkspace 'hosts') -PairId $scanProfile.HostId -PlanHash $segmentHash -OperationId $replayCancelId
    $replayPartial=& $module { param($workspace,$profile,$inventory,$hash,$root,$token,$hook) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root '' $token 10 10 50000 $hook } $scanWorkspace $scanProfile $segmentInventory $segmentHash $replayRoot $replayToken ({param($checkpoint,$token)if([long]$checkpoint.ScannedEntryCount -ge 1){$null=Request-WsmCancellation -Token $token -Owner 'SourceCandidateDiscoveryTest' -Evidence 'Save a replay prefix'}})
    $replayTerminal=& $module { param($workspace,$profile,$inventory,$hash,$root,$scanId,$hook) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root $scanId $null 10 1 50000 $null $hook } $scanWorkspace $scanProfile $segmentInventory $segmentHash $replayRoot $replayPartial.ScanId ({param($path,$watch)[Threading.Thread]::Sleep(1200)})
    $replayArtifact=Get-Content -LiteralPath $replayTerminal.CandidatePath -Raw|ConvertFrom-Json
    Check ($replayTerminal.ScanStatus -ceq 'ReplayBudgetExceeded' -and -not $replayTerminal.ContinuationRequired -and @($replayArtifact.Gaps|Where-Object Reason -CEQ 'ReplayBudgetExceeded').Count -eq 1 -and $replayTerminal.ReportHash) 'seen-prefix replay counts against the cooperative wall-clock budget and produces a durable terminal gap instead of endless resumable retries'
    ExpectFailure { & $module { param($workspace,$profile,$inventory,$hash,$root,$scanId) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root $scanId $null 10 1 50000 } $scanWorkspace $scanProfile $segmentInventory $segmentHash $replayRoot $replayPartial.ScanId } 'replay-budget-exhausted checkpoint is explicitly terminal and cannot restart the same prefix'
    $outsidePath=Join-Path $tempRoot 'outside-report.html';[IO.File]::WriteAllText($outsidePath,'outside')
    $outsideArtifacts=& $module { param($workspace,$path) @(Get-WsmHtmlReportArtifacts 'SourceCandidateScan' @([pscustomobject]@{ReportPath=$path}) $workspace) } $workspace $outsidePath
    Check (@($outsideArtifacts).Count -eq 0) 'arbitrary HTML paths are not published as source scan reports'
    Write-Output ('TOTAL CHECKS: '+$checks)
}
finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
