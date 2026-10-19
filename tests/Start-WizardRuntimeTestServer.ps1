param(
    [Parameter(Mandatory)][ValidateSet('Source','Target')][string]$Role,
    [Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory)][string]$ReadyPath,
    [Parameter(Mandatory)][string]$StopFile,
    [Parameter(Mandatory)][string]$ResponseCapturePath,
    [Parameter(Mandatory)][string]$PayloadRoot,
    [switch]$DiagnosticSelfTest,
    [ValidateSet('ItemByItem','Automatic')][string]$WizardMode='ItemByItem'
)
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../src/WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
& $module {
    param($Role,$Workspace,$ReadyPath,$StopFile,$ResponseCapturePath,$PayloadRoot,$WizardMode)
    $script:FixtureCaptureRoot=$ResponseCapturePath;$script:FixtureCaptureSequence=0;$script:FixtureRole=$Role
    $script:FixtureCorrelationId=''
    $script:FixtureTimingRoot=Join-Path ([IO.Path]::GetDirectoryName($ResponseCapturePath)) 'callee-timings'
    [IO.Directory]::CreateDirectory($script:FixtureTimingRoot)|Out-Null
    $script:FixtureTimedOriginals=@{}
    $timedNames=@('Get-WsmWizardProjection','Get-WsmWizardRuntimeProjection','Get-WsmWizardTargetPackage','Get-WsmWizardTargetSnapshot','Test-WsmMigrationPackage','Get-WsmAssistiveCurrentSoftwareCatalog','Read-WsmMigrationPlan')
    $timedAvailability=@()
    foreach($timedName in $timedNames){
        $timedCommand=Get-Command -Name $timedName -CommandType Function -ErrorAction SilentlyContinue
        $installed=$null -ne $timedCommand
        $timedAvailability+=,[pscustomobject]@{Function=$timedName;Installed=$installed}
        if(-not $installed){continue}
        $script:FixtureTimedOriginals[$timedName]=$timedCommand.ScriptBlock
        $safeName=$timedName -replace '[^A-Za-z0-9_]','_'
        $wrapperText=@"
`$__wsmCallId=[Guid]::NewGuid().ToString('N')
`$__wsmPath=Join-Path `$script:FixtureTimingRoot ('$safeName-'+`$__wsmCallId+'.json')
`$__wsmStack=@(Get-PSCallStack|Select-Object -First 8|ForEach-Object {`$_.FunctionName})
`$__wsmWatch=[Diagnostics.Stopwatch]::StartNew()
`$__wsmOutcome='Returned'
`$__wsmError=$null
`$__wsmEntry=[pscustomobject]@{Function='$timedName';InvocationId=`$__wsmCallId;Status='Running';StartedUtc=[DateTime]::UtcNow.ToString('o');CallStack=`$__wsmStack}
[IO.File]::WriteAllText(`$__wsmPath,(`$__wsmEntry|ConvertTo-Json -Compress -Depth 5),[Text.Encoding]::UTF8)
try{ & (`$script:FixtureTimedOriginals['$timedName']) @args }
catch{
    `$__wsmOutcome='Threw'
    `$record=`$_
    `$innerTypes=@();`$inner=`$record.Exception
    for(`$depth=0;`$inner -and `$depth -lt 8;`$depth++){`$innerTypes+=`$inner.GetType().FullName;`$inner=`$inner.InnerException}
    `$__wsmError=[pscustomobject]@{ExceptionType=`$record.Exception.GetType().FullName;Message=`$record.Exception.Message;InnerExceptionTypes=`$innerTypes;FullyQualifiedErrorId=`$record.FullyQualifiedErrorId;Category=`$record.CategoryInfo.Category.ToString();ScriptStackTrace=`$record.ScriptStackTrace;PositionMessage=`$record.InvocationInfo.PositionMessage}
    throw
}
finally{
    `$__wsmWatch.Stop()
    `$__wsmEntry=[pscustomobject]@{Function='$timedName';InvocationId=`$__wsmCallId;Status=`$__wsmOutcome;ElapsedMilliseconds=`$__wsmWatch.ElapsedMilliseconds;StartedUtc=`$__wsmEntry.StartedUtc;CompletedUtc=[DateTime]::UtcNow.ToString('o');CallStack=`$__wsmStack;Error=`$__wsmError}
    [IO.File]::WriteAllText(`$__wsmPath,(`$__wsmEntry|ConvertTo-Json -Compress -Depth 5),[Text.Encoding]::UTF8)
}
"@
        Set-Item -Path ("Function:\$timedName") -Value ([scriptblock]::Create($wrapperText))
    }
    [IO.File]::WriteAllText((Join-Path $script:FixtureTimingRoot "$Role-installed.json"),($timedAvailability|ConvertTo-Json -Depth 4),[Text.Encoding]::UTF8)
    $script:TestOriginalReadRequest=${function:Read-WsmLocalHttpRequest}
    $script:TestOriginalWriter=${function:Write-WsmLocalHttpResponse}
    $script:TestOriginalSafeError=${function:Get-WsmHtmlSafeError}
    function Read-WsmLocalHttpRequest($Client,[int]$MaximumBodyBytes=1048576,[ValidateRange(10,30000)][int]$MaximumRequestMilliseconds=5000){
        $parsed=& $script:TestOriginalReadRequest $Client $MaximumBodyBytes $MaximumRequestMilliseconds
        $script:FixtureCorrelationId=''
        try{$target=New-Object Uri('http://127.0.0.1'+[string]$parsed.Target);foreach($part in $target.Query.TrimStart('?').Split('&')){if($part){$kv=$part.Split('=',2);$key=[Uri]::UnescapeDataString($kv[0]);if($key -ceq '__formalCaptureId' -and $kv.Count -gt 1){$candidate=[Uri]::UnescapeDataString($kv[1]);if($candidate -match '^[a-f0-9-]{36}$'){$script:FixtureCorrelationId=$candidate};break}}}}catch{}
        return $parsed
    }
    function script:Get-WsmHtmlSafeError([string]$ExceptionMessage,[string]$ExceptionType=''){
        # This listener only serves a controlled formal fixture. Capture bounded
        # exception metadata before the product converts it to its safe response;
        # never record request bodies, workspace files, or arbitrary host logs.
        if($script:FixtureRole -ceq 'Target' -and $script:FixtureCaptureRoot){
            $errorRecord=if($_ -is [Management.Automation.ErrorRecord]){$_}else{$null}
            $innerDetails=@();$journalMismatch=$null;$inner=if($errorRecord){$errorRecord.Exception}else{$null}
            for($depth=0;$inner -and $depth -lt 8;$depth++){
                $innerDetails+=,[pscustomobject]@{Type=$inner.GetType().FullName;Message=([string]$inner.Message).Substring(0,[Math]::Min(2000,([string]$inner.Message).Length))}
                if(-not $journalMismatch -and $inner.Data -and $inner.Data.Contains('WsmJournalMismatchPredicate')){
                    $predicate=[string]$inner.Data['WsmJournalMismatchPredicate']
                    $expected=$inner.Data['WsmJournalExpectedSequence'];$observed=$inner.Data['WsmJournalObservedSequence']
                    $samePair=$inner.Data['WsmJournalSamePair'];$sameRun=$inner.Data['WsmJournalSameRun'];$previousHashMatches=$inner.Data['WsmJournalPreviousHashMatches']
                    if($predicate -in @('Sequence','PreviousHash','PairId','RunId') -and $expected -is [ValueType] -and $observed -is [ValueType] -and $samePair -is [bool] -and $sameRun -is [bool] -and $previousHashMatches -is [bool]){
                        $journalMismatch=[pscustomobject]@{Predicate=$predicate;ExpectedSequence=[long]$expected;ObservedSequence=[long]$observed;SamePair=$samePair;SameRun=$sameRun;PreviousHashMatches=$previousHashMatches}
                    }
                }
                $inner=$inner.InnerException
            }
            $entry=[ordered]@{
                SchemaVersion=1;DiagnosticId=[Guid]::NewGuid().ToString('D');Role='Target';FixtureScope='ControlledWizardRuntime'
                EngineVersion=$PSVersionTable.PSVersion.ToString();Transport=if($env:WSM_RUNTIME_NATIVE_TRANSPORT -eq '1'){'native-http-edge'}else{'formal-capture-bridge'}
                SourceCommit=$env:WSM_NATIVE_EVIDENCE_SOURCE_SHA;RunId=if($env:GITHUB_RUN_ID){$env:GITHUB_RUN_ID+'-'+$env:GITHUB_RUN_ATTEMPT}else{''}
                ObservedUtc=[DateTime]::UtcNow.ToString('o');ExceptionType=$ExceptionType
                Message=([string]$ExceptionMessage).Substring(0,[Math]::Min(4000,([string]$ExceptionMessage).Length))
                FullyQualifiedErrorId=if($errorRecord){$errorRecord.FullyQualifiedErrorId}else{''}
                Category=if($errorRecord){$errorRecord.CategoryInfo.Category.ToString()}else{''}
                InnerExceptions=$innerDetails
                ScriptStackTrace=if($errorRecord){([string]$errorRecord.ScriptStackTrace).Substring(0,[Math]::Min(8000,([string]$errorRecord.ScriptStackTrace).Length))}else{''}
                PositionMessage=if($errorRecord){([string]$errorRecord.InvocationInfo.PositionMessage).Substring(0,[Math]::Min(2000,([string]$errorRecord.InvocationInfo.PositionMessage).Length))}else{''}
                CallStack=@(Get-PSCallStack|Select-Object -First 12|ForEach-Object {[string]$_.FunctionName})
            }
            if($journalMismatch){$entry.JournalMismatch=$journalMismatch}
            $diagnosticPath=Join-Path ([IO.Path]::GetDirectoryName($script:FixtureCaptureRoot)) 'safe-error-diagnostics.jsonl'
            [IO.File]::AppendAllText($diagnosticPath,(($entry|ConvertTo-Json -Compress -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
        }
        & $script:TestOriginalSafeError $ExceptionMessage $ExceptionType
    }
    function Write-WsmLocalHttpResponse($Client,[int]$Status,[string]$ContentType,[byte[]]$Bytes){
        $sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        if($script:FixtureCaptureRoot){$script:FixtureCaptureSequence++;$correlationId=[string]$script:FixtureCorrelationId;$name=if($correlationId -match '^[a-f0-9-]{36}$'){$script:FixtureCaptureSequence.ToString()+'-'+$correlationId+'.json'}else{$script:FixtureCaptureSequence.ToString()+'.json'};$record=[pscustomobject]@{Sequence=$script:FixtureCaptureSequence;CorrelationId=$correlationId;Status=$Status;ContentType=$ContentType;SHA256=$hash;Payload=[Convert]::ToBase64String($Bytes)};Write-WsmJson (Join-Path $script:FixtureCaptureRoot $name) $record}
        & $script:TestOriginalWriter $Client $Status $ContentType $Bytes
    }
    if($DiagnosticSelfTest){
        $worker=[Management.Automation.PowerShell]::Create()
        try{
            $runspace=[Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace();$runspace.Open();$worker.Runspace=$runspace
            [void]$worker.AddScript("`$journal=[IO.InvalidDataException]::new('journal detail');`$journal.Data['WsmJournalMismatchPredicate']='PreviousHash';`$journal.Data['WsmJournalExpectedSequence']=[long]7;`$journal.Data['WsmJournalObservedSequence']=[long]8;`$journal.Data['WsmJournalSamePair']=`$true;`$journal.Data['WsmJournalSameRun']=`$false;`$journal.Data['WsmJournalPreviousHashMatches']=`$false;`$e=[InvalidOperationException]::new('controlled diagnostic failure token=TOKENCANARY body=BODYCANARY',`$journal);`$e.Data['WsmJournalRawHash']='HASHCANARY';throw `$e")
            $async=$worker.BeginInvoke()
            try{$null=$worker.EndInvoke($async);throw 'Diagnostic worker unexpectedly returned successfully.'}
            catch{
                $workerRecord=if($worker.Streams.Error.Count){$worker.Streams.Error[0]}else{$_}
                try{throw $workerRecord}catch{$safe=Get-WsmHtmlSafeError ([string]$workerRecord.Exception.Message) $workerRecord.Exception.GetType().FullName}
            }
            $result=[ordered]@{SafeResponse=$safe;WorkerErrorCount=$worker.Streams.Error.Count;CapturedPath=(Join-Path ([IO.Path]::GetDirectoryName($ResponseCapturePath)) 'safe-error-diagnostics.jsonl')}
            [IO.File]::WriteAllText($ReadyPath,($result|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
        }finally{if($worker){$worker.Dispose()};if($runspace){$runspace.Close();$runspace.Dispose()}}
        return
    }
    $sourceRoot=Join-Path $Workspace 'source';$managerRoot=Join-Path $Workspace 'manager';$targetRoot=Join-Path $Workspace 'target'
    $env:WSM_RUNTIME_TEST_FINGERPRINT='a'*64;$sourceProfile=Initialize-WsmOutputWorkspace $sourceRoot Source
    $env:WSM_RUNTIME_TEST_FINGERPRINT='b'*64;$targetProfile=Initialize-WsmOutputWorkspace $targetRoot Target
    $env:WSM_RUNTIME_TEST_FINGERPRINT=if($Role -ceq 'Source'){'a'*64}else{'b'*64}
    [void](Initialize-WsmOutputWorkspace $managerRoot Manager);Initialize-WsmWorkspace $managerRoot|Out-Null
    # The source policy classifies C: versus NonC from the reviewed path. The
    # short workspace alias used by this harness is a subst drive, so payload
    # bytes live under the caller's ordinary C: temp root instead.
    $sourceData=Join-Path $PayloadRoot 'source-payload';[void][IO.Directory]::CreateDirectory($sourceData)
    [IO.File]::WriteAllText((Join-Path $sourceData 'fixture.txt'),'formal runtime payload bytes')
    [IO.File]::WriteAllText((Join-Path $sourceData 'settings.ini'),'immutable source settings')
    $source=[pscustomobject]@{HostId=$sourceProfile.HostId;Fingerprint=$sourceProfile.Profile.Fingerprint;Name='Formal source'}
    $item=New-WsmItem $source.HostId Storage DataRoot 'Formal runtime folder' 'formal-runtime-folder' ([pscustomobject]@{Path=$sourceData}) @() Success FileScope
    $inventory=New-WsmInventory $source 1 @($item)
    $inventory|Add-Member NoteProperty SoftwareCatalog ([pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SoftwareCatalog';Source=[pscustomobject][ordered]@{HostId=$source.HostId;Fingerprint=$source.Fingerprint;Name=$source.Name;InventoryRevision=1;InventoryProjectionHash=(Get-WsmSoftwareInventoryProjectionHash $inventory)};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=(Get-WsmUtc);CaptureIdentity='formal controlled inventory fixture';AccountContext='System';CaptureHost='formal-runtime-fixture';PowerShellVersion='5.1';RequestedPortableRoots=@()};Entries=@();Coverage=@([pscustomobject][ordered]@{Probe='Fixture';Scope='Machine';SID='';View='Fixture';Status='Success';EvidenceKind='ControlledNativeObservation';Count=0;Budget=[pscustomobject]@{MaxEntries=100};ErrorKind=$null;ObservedUtc=(Get-WsmUtc)});PreparationRequirements=@();CatalogProjectionHash=('0'*64)}) -Force
    $inventory.SoftwareCatalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $inventory.SoftwareCatalog
    Assert-WsmSoftwareCatalog $inventory.SoftwareCatalog -SourceInventory $inventory|Out-Null
    $inventoryPath=Join-Path $Workspace 'source-inventory.json';Write-WsmJson $inventoryPath $inventory;$env:WSM_RUNTIME_TEST_INVENTORY_PATH=[IO.Path]::GetFullPath($inventoryPath)
    $catalog=Import-WsmInventory $managerRoot $inventoryPath (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash 'Formal target'
    $catalog=Enable-WsmAssistiveMode $managerRoot $catalog.PairId $catalog.DecisionRevision
    $targetIdentityPath=Join-Path (Join-Path $targetRoot ('targets\'+$targetProfile.HostId)) 'target-identity.json'
    $targetIdentityHash=(Get-FileHash -LiteralPath $targetIdentityPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $spec=[pscustomobject][ordered]@{Adapter='FileScope';SourcePath=$sourceData;TargetPath=(Join-Path $Workspace 'restored-payload');TransferChannel='C';ContentSelection='WholeScope';ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='AllowAutoInheritedUpgrade';ConflictPolicy='ReplaceOwned';Owner='Fixture source owner';Evidence='Immutable source payload fixture';BusinessChecks=@('Read back each exact fixture file')}
    $specPath=Join-Path $Workspace 'approved-spec.json';Write-WsmJson $specPath $spec
    $catalog=Get-WsmCatalog $managerRoot $catalog.PairId
    Set-WsmMigrationSpec $managerRoot $catalog.PairId $item.ItemId $specPath (Get-FileHash -LiteralPath $specPath -Algorithm SHA256).Hash $catalog.DecisionRevision|Out-Null
    $catalog=Get-WsmCatalog $managerRoot $catalog.PairId
    $catalog=Set-WsmDecision $managerRoot $catalog.PairId @($item.ItemId) Include 'Formal runtime fixture' $catalog.DecisionRevision
    $approvedPath=Join-Path $Workspace 'approved-plan.json'
    $approved=Approve-WsmMigrationPlan $managerRoot $catalog.PairId $targetIdentityPath $targetIdentityHash $approvedPath $catalog.DecisionRevision 'ISOLATED-PILOT'
    $approvalJob=[pscustomobject][ordered]@{jobId=[Guid]::NewGuid().ToString('D');operationId='';action='ApproveMigration';role='Manager';workspace=$managerRoot;pairId=$catalog.PairId;status='Succeeded';CompletedUtc=(Get-WsmUtc);outputs=@([pscustomobject]@{Path=[IO.Path]::GetFullPath($approvedPath);SHA256=[string]$approved.SHA256})}
    if($Role -ceq 'Source'){
        $env:WSM_RUNTIME_TEST_FINGERPRINT='a'*64;$received=Import-WsmWizardApprovedPlan $sourceRoot Source $approvedPath $approved.SHA256
        if($received.Status -cne 'ImportedVerified'){throw 'Controlled Source did not import the core-approved schema-3 plan.'}
        $state=Get-WsmWizardState $sourceRoot $catalog.PairId Source
        Set-WsmWizardState $sourceRoot $catalog.PairId Source $state.Revision ([pscustomobject]@{CurrentStep='backup';Mode=$WizardMode})|Out-Null
        $profilePath=Join-Path (Join-Path $sourceRoot 'workspace-control') 'output-profile.json'
        $profileHash=(Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $fixture=[pscustomobject][ordered]@{Role='Source';PairId=$catalog.PairId;ItemId=$item.ItemId;SourceData=$sourceData;PlanPath=$approvedPath;PlanHash=$approved.SHA256;ProfilePath=$profilePath;ProfileHash=$profileHash;WizardMode=$WizardMode}
    } else {
        $env:WSM_RUNTIME_TEST_FINGERPRINT='a'*64;$sourceReceived=Import-WsmWizardApprovedPlan $sourceRoot Source $approvedPath $approved.SHA256
        if($sourceReceived.Status -cne 'ImportedVerified'){throw 'Controlled Target setup could not bind the approved plan to Source.'}
        $sourceBackup=Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $catalog.PairId -OperationId ([Guid]::NewGuid().ToString('D')) -DeliveryMode Directory -VolumeBytes 0 -Jobs @()
        if($sourceBackup.Status -cne 'Delivered' -or $sourceBackup.Delivery.Mode -cne 'Directory' -or -not $sourceBackup.Delivery.Directory){throw 'Controlled Target setup could not produce a real sealed Directory package.'}
        $targetData=Join-Path $Workspace 'target-restore-root'
        $targetFacts=[pscustomobject]@{HostId=$targetProfile.HostId;Fingerprint=$targetProfile.Profile.Fingerprint;Name='Formal target'}
        $targetItem=New-WsmItem $targetFacts.HostId Services Service 'Target fixture service' 'FixtureSvc' ([pscustomobject]@{Name='FixtureSvc';Status='Observed'}) @() Success Manual
        $targetInventory=New-WsmInventory $targetFacts 1 @($targetItem)
        $targetInventory|Add-Member NoteProperty SoftwareCatalog ([pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SoftwareCatalog';Source=[pscustomobject][ordered]@{HostId=$targetFacts.HostId;Fingerprint=$targetFacts.Fingerprint;Name=$targetFacts.Name;InventoryRevision=1;InventoryProjectionHash=(Get-WsmSoftwareInventoryProjectionHash $targetInventory)};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=(Get-WsmUtc);CaptureIdentity='formal controlled native observation fixture';AccountContext='System';CaptureHost='formal-runtime-fixture';PowerShellVersion='5.1';RequestedPortableRoots=@()};Entries=@();Coverage=@([pscustomobject][ordered]@{Probe='Fixture';Scope='Machine';SID='';View='Fixture';Status='Success';EvidenceKind='ControlledNativeObservation';Count=0;Budget=[pscustomobject]@{MaxEntries=100};ErrorKind=$null;ObservedUtc=(Get-WsmUtc)});PreparationRequirements=@();CatalogProjectionHash=('0'*64)}) -Force
        $targetInventory.SoftwareCatalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $targetInventory.SoftwareCatalog
        Assert-WsmSoftwareCatalog $targetInventory.SoftwareCatalog -SourceInventory $targetInventory|Out-Null
        $targetInventoryRoot=Join-Path (Join-Path (Join-Path $targetRoot ('hosts\'+$targetProfile.Profile.Fingerprint)) 'inventory') '';[void][IO.Directory]::CreateDirectory($targetInventoryRoot)
        $targetInventoryPath=Join-Path $targetInventoryRoot 'inventory-1.json';Write-WsmJson $targetInventoryPath $targetInventory;$env:WSM_RUNTIME_TEST_INVENTORY_PATH=[IO.Path]::GetFullPath($targetInventoryPath)
        $targetInventoryHash=(Get-FileHash -LiteralPath $targetInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        # This pre-seeded controlled native observation is consumed before the
        # listener starts, so give its durable console record the same request
        # identity fields that startup reconciliation requires for every job.
        $targetInventoryArgs=@{OutputDirectory=$targetInventoryRoot;DeepDiscovery=$false}
        $targetInventoryJob=[pscustomobject][ordered]@{jobId=[Guid]::NewGuid().ToString('D');operationId='';idempotencyKey=[Guid]::NewGuid().ToString('D');RequestHash=(Get-WsmHtmlRequestHash $targetRoot $catalog.PairId 'Target' 'Inventory' $targetInventoryArgs 0);action='Inventory';role='Target';workspace=$targetRoot;pairId=$catalog.PairId;status='Succeeded';CompletedUtc=(Get-WsmUtc);outputs=@([pscustomobject]@{Path=$targetInventoryPath;SHA256=$targetInventoryHash;Revision=1})}
        $targetJobRoot=Join-Path $targetRoot 'console-jobs';[void][IO.Directory]::CreateDirectory($targetJobRoot);Write-WsmJson (Join-Path $targetJobRoot ($targetInventoryJob.jobId+'.json')) $targetInventoryJob
        Set-WsmWizardInventoryBinding -Workspace $targetRoot -Role Target -JobId $targetInventoryJob.jobId -ExpectedWizardRevision 0 -Jobs @($targetInventoryJob)|Out-Null
        $managerRevision=[int](Get-WsmCatalog $managerRoot $catalog.PairId).Assistive.Revision
        Update-WsmAssistiveTargetSnapshot -Workspace $managerRoot -PairId $catalog.PairId -Path $targetInventoryPath -ExpectedHash $targetInventoryHash -ExpectedRevision $managerRevision|Out-Null
        $managerRevision=[int](Get-WsmCatalog $managerRoot $catalog.PairId).Assistive.Revision
        Update-WsmAssistiveComparison -Workspace $managerRoot -PairId $catalog.PairId -ExpectedRevision $managerRevision|Out-Null
        $comparison=Export-WsmWizardTargetComparison -Workspace $managerRoot -PairId $catalog.PairId -Jobs @($approvalJob)
        $targetState=Get-WsmWizardState $targetRoot $catalog.PairId Target
        Set-WsmWizardState $targetRoot $catalog.PairId Target $targetState.Revision ([pscustomobject]@{CurrentStep='handoff';Mode='ItemByItem'})|Out-Null
        $profilePath=Join-Path (Join-Path $targetRoot 'workspace-control') 'output-profile.json'
        $profileHash=(Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $fixture=[pscustomobject][ordered]@{Role='Target';PairId=$catalog.PairId;ItemId=$item.ItemId;TargetItemId=$targetItem.ItemId;PlanPath=$approvedPath;PlanHash=$approved.SHA256;Directory=$sourceBackup.Delivery.Directory;SummaryPath=$sourceBackup.Delivery.Path;SummaryHash=$sourceBackup.Delivery.SHA256;ComparisonPath=$comparison.Path;ComparisonHash=$comparison.SHA256;InventoryPath=$targetInventoryPath;InventoryHash=$targetInventoryHash;ProfilePath=$profilePath;ProfileHash=$profileHash;PayloadName='fixture.txt';PayloadText='formal runtime payload bytes';RestorePath=(Join-Path $Workspace 'restored-payload')}
    }
    Write-WsmJson ($ReadyPath+'.fixture') $fixture
    $consoleWorkspace=if($Role -ceq 'Source'){$sourceRoot}else{$targetRoot}
    $consolePair=if($Role -ceq 'Target'){''}else{$catalog.PairId}
    # Restore the listener/worker's controlled native identity after setup helpers
    # temporarily impersonate the Source while creating the approved package.
    $expectedRuntimeFingerprint=if($Role -ceq 'Source'){('a'*64)}else{('b'*64)}
    $env:WSM_RUNTIME_TEST_FINGERPRINT=$expectedRuntimeFingerprint
    $runtimeProfile=Read-WsmOutputProfile $consoleWorkspace
    $runtimeIdentity=Get-WsmMachineIdentity
    if(-not $runtimeProfile -or $runtimeProfile.Role -cne $Role -or $runtimeProfile.Fingerprint -ine $expectedRuntimeFingerprint -or $runtimeIdentity.Fingerprint -ine $runtimeProfile.Fingerprint){throw 'Controlled runtime identity does not match the enrolled role profile.'}
    # Fail during controlled fixture preparation with the underlying safe
    # helper exception rather than later as a generic HTTP operation error.
    [void](Get-WsmHtmlContext $consoleWorkspace $consolePair $Role ([Guid]::NewGuid().ToString()))
    try{Start-WsmHtmlConsole -Workspace $consoleWorkspace -PairId $consolePair -Role $Role -NoBrowser -ReadyPath $ReadyPath -StopFile $StopFile}
    catch{
        $tracePath=Join-Path ([IO.Path]::GetDirectoryName($ResponseCapturePath)) 'startup-exception-diagnostics.log'
        $detail=@('Message: '+$_.Exception.Message,'Exception: '+$_.Exception.ToString(),'ScriptStackTrace: '+$_.ScriptStackTrace,'Position: '+$_.InvocationInfo.PositionMessage) -join [Environment]::NewLine
        [IO.File]::WriteAllText($tracePath,$detail,(New-Object Text.UTF8Encoding($false)))
        throw
    }
} $Role $Workspace $ReadyPath $StopFile $ResponseCapturePath $PayloadRoot $WizardMode
