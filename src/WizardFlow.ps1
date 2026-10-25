function Get-WsmWizardStatePath([string]$Workspace,[string]$PairId,[string]$Role) {
    if($Role -cnotin @('Source','Manager','Target')){throw 'Unknown workspace role.'}
    if($PairId){Assert-WsmId $PairId;$key=$PairId.ToLowerInvariant()}else{$key='unbound'}
    Join-Path (Join-Path (Join-Path (Join-Path $Workspace 'workspace-control') 'wizard') $Role) ($key+'.json')
}

function Assert-WsmWizardState($State,$Profile,[string]$PairId) {
    Assert-WsmEnvelope $State 'WizardState'
    if($State.SchemaVersion -ne 1 -or $State.WizardVersion -ne 1){throw (New-WsmContractError 'Unsupported wizard state schema or version.')}
    foreach($field in @('ProfileId','Role','PairId','Revision','CurrentStep','ReviewGroupId','Mode','AutoContinue','SourceInventoryHash','SourceInventoryRevision','InventoryJobId','SourceIntent','ConfirmedItemIds','ConfirmationContext','ConfirmationSelectionRevision','OperationIds','UpdatedUtc')){if(-not $State.PSObject.Properties[$field]){throw (New-WsmContractError ('Wizard state missing '+$field+'.'))}}
    if($State.ProfileId -cne $Profile.ProfileId -or $State.Role -cne $Profile.Role -or $State.PairId -cne $PairId){throw (New-WsmContractError 'Wizard state is bound to another role, pair, or workspace profile.')}
    if(($State.Revision -isnot [int] -and $State.Revision -isnot [long]) -or $State.Revision -lt 0 -or $State.SourceInventoryRevision -lt 0){throw (New-WsmContractError 'Wizard state revision is invalid.')}
    if($State.CurrentStep -cnotin @('start','prepare','scan','review','backup','handoff','restore','validate','result')){throw (New-WsmContractError 'Wizard state has an unknown current step.')}
    if($State.ReviewGroupId -and [string]$State.ReviewGroupId -notmatch '^wg-[a-f0-9]{24}$'){throw (New-WsmContractError 'Wizard review group identity is invalid.')}
    if($State.Mode -cnotin @('ItemByItem','Automatic')){throw (New-WsmContractError 'Wizard state has an unknown mode.')}
    if($State.AutoContinue -isnot [bool] -or $State.SourceIntent -isnot [array] -or $State.ConfirmedItemIds -isnot [array] -or $State.OperationIds -isnot [array] -or ($State.ConfirmationSelectionRevision -isnot [int] -and $State.ConfirmationSelectionRevision -isnot [long])){throw (New-WsmContractError 'Wizard state collection or flag types are invalid.')}
    if($State.SourceInventoryHash -and [string]$State.SourceInventoryHash -notmatch '^[a-f0-9]{64}$'){throw (New-WsmContractError 'Wizard source inventory hash is invalid.')}
    if($State.InventoryJobId){Assert-WsmId ([string]$State.InventoryJobId)}
    $seen=@{};foreach($row in @($State.SourceIntent)){
        Assert-WsmFields $row @('ItemId','Selected','Reason','InventoryHash','InventoryRevision','UpdatedUtc','Confirmed') @('ItemId','Selected','Reason','InventoryHash','InventoryRevision','UpdatedUtc')
        if([string]$row.ItemId -notmatch '^[a-f0-9]{64}$' -or $seen.ContainsKey([string]$row.ItemId) -or $row.Selected -isnot [bool] -or $row.InventoryHash -cne $State.SourceInventoryHash -or [long]$row.InventoryRevision -ne [long]$State.SourceInventoryRevision){throw (New-WsmContractError 'Source intent is malformed or belongs to a different inventory generation.')}
        if($row.PSObject.Properties['Confirmed'] -and $row.Confirmed -isnot [bool]){throw (New-WsmContractError 'Source intent confirmation flag is invalid.')}
        if(-not $row.Selected -and [string]::IsNullOrWhiteSpace([string]$row.Reason)){throw (New-WsmContractError 'Excluded source intent needs a reason.')}
        $seen[[string]$row.ItemId]=$true
    }
    foreach($id in @($State.OperationIds)){Assert-WsmId ([string]$id)}
    try{[void][DateTimeOffset]::Parse([string]$State.UpdatedUtc)}catch{throw (New-WsmContractError 'Wizard state timestamp is invalid.')}
    $true
}

function New-WsmWizardState($Profile,[string]$PairId) {
    [pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='WizardState';WizardVersion=1;ProfileId=[string]$Profile.ProfileId;Role=[string]$Profile.Role;PairId=$PairId;Revision=0;CurrentStep='start';ReviewGroupId='';Mode='ItemByItem';AutoContinue=$false;SourceInventoryHash='';SourceInventoryRevision=0;InventoryJobId='';SourceIntent=[object[]]@();ConfirmedItemIds=[object[]]@();ConfirmationContext='';ConfirmationSelectionRevision=0;AutomaticReview=$null;RemainderReview=$null;OperationIds=[object[]]@();UpdatedUtc=(Get-WsmUtc)}
}

function Get-WsmWizardState {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[string]$PairId='',[Parameter(Mandatory)][ValidateSet('Source','Manager','Target')][string]$Role)
    $profile=Read-WsmOutputProfile $Workspace
    if(-not $profile){throw 'Initialize this workspace for its role before opening the wizard.'}
    if($profile.Role -cne $Role){throw 'Wizard role does not match the enrolled workspace role.'}
    if($PairId){Assert-WsmId $PairId}
    $path=Get-WsmWizardStatePath $Workspace $PairId $Role
    Invoke-WsmLocked $Workspace {
        if([IO.File]::Exists($path)){Assert-WsmNoReparse $path;$state=Read-WsmJson $path;Assert-WsmWizardState $state $profile $PairId | Out-Null;return $state}
        New-WsmWizardState $profile $PairId
    }
}

function Assert-WsmWizardProbeCancellationDirectory([string]$Path) {
    Assert-WsmNoReparse $Path
    if(-not [IO.Directory]::Exists($Path)){throw 'Developer probe cancellation path is not a directory.'}
    foreach($markerFile in @(Get-ChildItem -LiteralPath $Path -Force)){
        Assert-WsmNoReparse $markerFile.FullName;$markerId=[Guid]::Empty;$markerName=[IO.Path]::GetFileNameWithoutExtension($markerFile.Name)
        if($markerFile.PSIsContainer -or $markerFile.Extension -cne '.json' -or -not [Guid]::TryParseExact($markerName,'D',[ref]$markerId) -or $markerId.ToString('D') -cne $markerName.ToLowerInvariant() -or $markerFile.Length -gt 4096){throw 'Unrecognized developer probe cancellation data blocks first-use role setup.'}
        $marker=ConvertFrom-WsmJson ([IO.File]::ReadAllText($markerFile.FullName,[Text.Encoding]::UTF8))
        if([string]$marker.Kind -cne 'DeveloperProbeCancellationRequest' -or [string]$marker.OperationId -cne $markerId.ToString('D')){throw 'Developer probe cancellation marker identity is invalid.'}
        $requestedUtc=[DateTimeOffset]::MinValue;if(-not [DateTimeOffset]::TryParse([string]$marker.RequestedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$requestedUtc) -or $requestedUtc.Offset -ne [TimeSpan]::Zero){throw 'Developer probe cancellation marker timestamp is invalid.'}
    }
}

function Initialize-WsmWizardWorkspace {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][ValidateSet('Source','Manager','Target')][string]$Role)
    $root=[IO.Path]::GetFullPath($Workspace)
    if([IO.File]::Exists((Join-Path (Join-Path $root 'workspace-control') 'output-profile.json'))){$profile=Read-WsmOutputProfile $root;if($profile.Role -cne $Role){throw 'This workspace is already enrolled for another role; its role cannot be changed.'};return $profile}
    if([IO.Directory]::Exists($root)){
        $bootstrap=@('.wsm.lock','console-worker.lock','console-probe-worker.lock','console-jobs','console-errors','developer-probes')
        foreach($entry in @(Get-ChildItem -LiteralPath $root -Force)){
            if($entry.Name -notin $bootstrap){throw ('This workspace contains unowned state ('+$entry.Name+') without a role profile; preserve it and choose its existing workflow or perform an explicit workspace migration.')}
            Assert-WsmNoReparse $entry.FullName
            if($entry.Name -in @('.wsm.lock','console-worker.lock','console-probe-worker.lock') -and $entry.PSIsContainer){throw 'The local workspace lock path is occupied by a directory.'}
            if($entry.Name -in @('console-jobs','console-errors') -and -not $entry.PSIsContainer){throw 'A local console state directory is occupied by a file.'}
            if($entry.Name -eq 'developer-probes'){
                if(-not $entry.PSIsContainer){throw 'The developer probe root is occupied by a file.'}
                $rootCancellationPath=Join-Path $entry.FullName '.cancellations';if([IO.Directory]::Exists($rootCancellationPath)){Assert-WsmWizardProbeCancellationDirectory $rootCancellationPath};if([IO.File]::Exists($rootCancellationPath)){throw 'Developer probe cancellation path is occupied by a file.'}
                foreach($run in @(Get-ChildItem -LiteralPath $entry.FullName -Force | Where-Object {$_.Name -cne '.cancellations'})){$runId=[Guid]::Empty;Assert-WsmNoReparse $run.FullName;if(-not $run.PSIsContainer -or -not [Guid]::TryParseExact([string]$run.Name,'D',[ref]$runId) -or $runId.ToString('D') -cne [string]$run.Name.ToLowerInvariant()){throw 'Unrecognized content exists in the developer probe root; role setup was not changed.'};$allowedRun=@('protected-raw','probe.json','index.html','files-index.json','developer-probe.zip');foreach($child in @(Get-ChildItem -LiteralPath $run.FullName -Force)){Assert-WsmNoReparse $child.FullName;if($child.Name -ceq '.cancellations'){
                        if(-not $child.PSIsContainer){throw 'Developer probe cancellation path is not a directory.'}
                        Assert-WsmWizardProbeCancellationDirectory $child.FullName
                        continue
                    };if($child.Name -notin $allowedRun){throw 'Unrecognized developer probe output blocks first-use role setup.'};if($child.Name -eq 'protected-raw'){if(-not $child.PSIsContainer){throw 'Protected developer probe evidence path is not a directory.'};$pending=New-Object 'System.Collections.Generic.Stack[string]';$pending.Push($child.FullName);while($pending.Count){$directory=$pending.Pop();Assert-WsmNoReparse $directory;foreach($raw in @(Get-ChildItem -LiteralPath $directory -Force)){Assert-WsmNoReparse $raw.FullName;if($raw.PSIsContainer){$pending.Push($raw.FullName)}}}}elseif($child.PSIsContainer){throw 'Developer probe deliverables must be regular files.'}}
                }
            }
        }
    }
    $initialized=Initialize-WsmOutputWorkspace -WorkRoot $root -Role $Role
    Initialize-WsmWorkspace $root | Out-Null
    $initialized.Profile
}

function Set-WsmWizardState {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[string]$PairId='',[Parameter(Mandatory)][ValidateSet('Source','Manager','Target')][string]$Role,[Parameter(Mandatory)][int]$ExpectedWizardRevision,[Parameter(Mandatory)]$Changes)
    if($ExpectedWizardRevision -lt 0){throw 'Expected wizard revision cannot be negative.'}
    $profile=Read-WsmOutputProfile $Workspace;if(-not $profile -or $profile.Role -cne $Role){throw 'Wizard role does not match an enrolled workspace.'}
    if($PairId){Assert-WsmId $PairId}
    Assert-WsmFields $Changes @('CurrentStep','ReviewGroupId','Mode','AutoContinue','SourceInventoryHash','SourceInventoryRevision','SourceIntent','ConfirmedItemIds','ConfirmationContext','ConfirmationSelectionRevision')
    if(@($Changes.PSObject.Properties|Where-Object {$_.Name -in @('SourceInventoryHash','SourceInventoryRevision','SourceIntent','ConfirmedItemIds','ConfirmationContext','ConfirmationSelectionRevision')}).Count){throw 'Wizard inventory bindings, choices and confirmations can only be changed by a verified wizard operation.'}
    $path=Get-WsmWizardStatePath $Workspace $PairId $Role
    Invoke-WsmLocked $Workspace {
        $state=if([IO.File]::Exists($path)){Assert-WsmNoReparse $path;$saved=Read-WsmJson $path;Assert-WsmWizardState $saved $profile $PairId | Out-Null;$saved}else{New-WsmWizardState $profile $PairId}
        if([int]$state.Revision -ne $ExpectedWizardRevision){throw 'Wizard progress changed; refresh before saving.'}
        foreach($field in $Changes.PSObject.Properties){$name=[string]$field.Name;$value=$field.Value
            switch($name){
                CurrentStep {if([string]$value -cnotin @('start','prepare','scan','review','backup','handoff','restore','validate','result')){throw 'Unknown wizard step.'};$state.CurrentStep=[string]$value}
                ReviewGroupId {if($value -and [string]$value -notmatch '^wg-[a-f0-9]{24}$'){throw 'Unknown review group identity.'};$state.ReviewGroupId=[string]$value}
                Mode {if([string]$value -cnotin @('ItemByItem','Automatic')){throw 'Unknown wizard mode.'};$state.Mode=[string]$value}
                AutoContinue {if($value -isnot [bool]){throw 'AutoContinue must be a boolean.'};$state.AutoContinue=[bool]$value}
            }
        }
        $state.Revision=[int]$state.Revision+1;$state.UpdatedUtc=Get-WsmUtc
        Assert-WsmWizardState $state $profile $PairId | Out-Null
        Write-WsmJson $path $state
        $state
    }
}

function Register-WsmWizardOperationJob([string]$Workspace,$JobRecord) {
    if(-not $JobRecord -or -not $JobRecord.PSObject.Properties['jobId'] -or -not $JobRecord.PSObject.Properties['workspace'] -or -not $JobRecord.PSObject.Properties['role'] -or -not $JobRecord.PSObject.Properties['pairId']){throw 'A durable local operation job record is required.'}
    Assert-WsmId ([string]$JobRecord.jobId)
    if([IO.Path]::GetFullPath([string]$JobRecord.workspace) -ine [IO.Path]::GetFullPath($Workspace)){throw 'Operation job belongs to another workspace.'}
    if([string]$JobRecord.action -ceq 'DeveloperProbe'){return $null}
    $profile=Read-WsmOutputProfile $Workspace;if(-not $profile -or $profile.Role -cne [string]$JobRecord.role){return $null}
    $pair=[string]$JobRecord.pairId;if($pair){Assert-WsmId $pair}
    $jobsRoot=[IO.Path]::GetFullPath((Join-Path $Workspace 'console-jobs'));$jobPath=[IO.Path]::GetFullPath((Join-Path $jobsRoot ($JobRecord.jobId+'.json')))
    if(-not $jobPath.StartsWith($jobsRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Operation job record path is outside the console history.'}
    Assert-WsmNoReparse $jobsRoot;Assert-WsmNoReparse $jobPath;if(-not [IO.File]::Exists($jobPath)){throw 'Operation job must be durable before wizard registration.'}
    $savedJob=Read-WsmJson $jobPath
    if([string]$savedJob.jobId -cne [string]$JobRecord.jobId -or [string]$savedJob.action -cne [string]$JobRecord.action -or [IO.Path]::GetFullPath([string]$savedJob.workspace) -ine [IO.Path]::GetFullPath($Workspace) -or [string]$savedJob.role -cne [string]$JobRecord.role -or [string]$savedJob.pairId -cne $pair -or [string]$savedJob.RequestHash -notmatch '^[a-f0-9]{64}$' -or [string]$savedJob.idempotencyKey -notmatch '^[a-fA-F0-9-]{36}$'){throw 'Durable operation record does not match the wizard context.'}
    $statePath=Get-WsmWizardStatePath $Workspace $pair $profile.Role
    Invoke-WsmLocked $Workspace {
        if([IO.File]::Exists($statePath)){Assert-WsmNoReparse $statePath;$state=Read-WsmJson $statePath;Assert-WsmWizardState $state $profile $pair | Out-Null}else{$state=New-WsmWizardState $profile $pair}
        if(@($state.OperationIds | Where-Object {$_ -ceq [string]$JobRecord.jobId}).Count){return $state}
        $state.OperationIds=[object[]]@(@($state.OperationIds)+@([string]$JobRecord.jobId)|Select-Object -Unique);$state.Revision=[int]$state.Revision+1;$state.UpdatedUtc=Get-WsmUtc
        Assert-WsmWizardState $state $profile $pair | Out-Null;Write-WsmJson $statePath $state;$state
    }
}

function Sync-WsmWizardOperationJobs([string]$Workspace,[object[]]$Jobs) {
    $profile=Read-WsmOutputProfile $Workspace;if(-not $profile){return @()}
    $registered=New-Object 'System.Collections.Generic.List[object]'
    foreach($job in @($Jobs)){if($job -and $job.PSObject.Properties['workspace'] -and [IO.Path]::GetFullPath([string]$job.workspace) -ieq [IO.Path]::GetFullPath($Workspace) -and $job.PSObject.Properties['role'] -and [string]$job.role -ceq $profile.Role -and [string]$job.action -cne 'DeveloperProbe'){$row=Register-WsmWizardOperationJob $Workspace $job;if($row){$registered.Add([string]$job.jobId)}}}
    @($registered.ToArray())
}

function Set-WsmWizardInventoryBinding {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][ValidateSet('Source','Target')][string]$Role,[Parameter(Mandatory)][string]$JobId,[Parameter(Mandatory)][int]$ExpectedWizardRevision,[Parameter(Mandatory)][object[]]$Jobs)
    Assert-WsmId $JobId;$profile=Read-WsmOutputProfile $Workspace;if(-not $profile -or $profile.Role -cne $Role){throw 'Inventory result role does not match this enrolled workspace.'}
    $candidate=Get-WsmWizardInventoryFromJobs $Workspace $profile $Jobs '' $JobId;if(-not $candidate -or ($candidate.PSObject.Properties['Ambiguous'] -and $candidate.Ambiguous)){throw 'Selected inventory job does not contain one verified inventory artifact.'}
    Invoke-WsmLocked $Workspace {
        $fresh=Get-WsmWizardInventoryFromJobs $Workspace $profile $Jobs '' $JobId;if(-not $fresh -or ($fresh.PSObject.Properties['Ambiguous'] -and $fresh.Ambiguous) -or $fresh.SHA256 -ine $candidate.SHA256){throw 'Review changed: selected inventory artifact.'}
        $path=Get-WsmWizardStatePath $Workspace '' $Role;if([IO.File]::Exists($path)){Assert-WsmNoReparse $path;$state=Read-WsmJson $path;Assert-WsmWizardState $state $profile '' | Out-Null}else{$state=New-WsmWizardState $profile ''}
        if([int]$state.Revision -ne $ExpectedWizardRevision){throw 'Review changed: wizard progress revision.'}
        if($state.SourceInventoryHash -ine $fresh.SHA256 -or [int]$state.SourceInventoryRevision -ne [int]$fresh.Inventory.Revision){
            $oldCandidate=$null;if($state.SourceInventoryHash){$oldCandidate=Get-WsmWizardInventoryFromJobs $Workspace $profile $Jobs ([string]$state.SourceInventoryHash) ([string]$state.InventoryJobId)}
            $oldItems=@{};if($oldCandidate -and -not $oldCandidate.Ambiguous){foreach($item in @($oldCandidate.Inventory.Items)){$oldItems[[string]$item.ItemId]=$item}}
            $newItems=@{};foreach($item in @($fresh.Inventory.Items)){$newItems[[string]$item.ItemId]=$item}
            $preserved=New-Object 'System.Collections.Generic.List[object]'
            foreach($row in @($state.SourceIntent)){
                $id=[string]$row.ItemId;if(-not $newItems.ContainsKey($id)){continue}
                $unchanged=$false;if($oldItems.ContainsKey($id)){$oldJson=$oldItems[$id]|ConvertTo-Json -Depth 40 -Compress;$newJson=$newItems[$id]|ConvertTo-Json -Depth 40 -Compress;$unchanged=(Get-WsmHashText $oldJson) -ceq (Get-WsmHashText $newJson)}
                $wasConfirmed=$true;if($row.PSObject.Properties['Confirmed']){$wasConfirmed=[bool]$row.Confirmed}
                $preserved.Add([pscustomobject]@{ItemId=$id;Selected=[bool]$row.Selected;Reason=[string]$row.Reason;InventoryHash=$fresh.SHA256;InventoryRevision=[int]$fresh.Inventory.Revision;Confirmed=($unchanged -and $wasConfirmed);UpdatedUtc=(Get-WsmUtc)})
            }
            $state.SourceIntent=[object[]]@($preserved.ToArray());$state.ConfirmedItemIds=[object[]]@();$state.ConfirmationContext='';$state.ConfirmationSelectionRevision=0
        }
        $state.SourceInventoryHash=$fresh.SHA256;$state.SourceInventoryRevision=[int]$fresh.Inventory.Revision;$state.InventoryJobId=$JobId;$state.Revision=[int]$state.Revision+1;$state.UpdatedUtc=Get-WsmUtc
        Assert-WsmWizardState $state $profile '' | Out-Null;Write-WsmJson $path $state
        [pscustomobject][ordered]@{Status='InventoryBound';Revision=[int]$state.Revision;InventoryJobId=$JobId;InventoryHash=$fresh.SHA256;InventoryRevision=[int]$fresh.Inventory.Revision;AuthoritativeApproval=$false}
    }
}

function Get-WsmWizardInventoryFromJobs([string]$Workspace,$Profile,[object[]]$Jobs,[string]$PreferredHash='',[string]$PreferredJobId='') {
    if(-not $Profile -or $Profile.Role -notin @('Source','Target')){return $null}
    $inventoryRoot=[IO.Path]::GetFullPath((Join-Path (Join-Path (Join-Path $Workspace ('hosts\'+$Profile.Fingerprint)) 'inventory') ''))
    $prefix=$inventoryRoot.TrimEnd('\')+'\';$candidates=New-Object 'System.Collections.Generic.List[object]'
    foreach($job in @($Jobs)){
        if($null -eq $job){continue}
        $job=ConvertTo-WsmNormalizedJobRecord $job
        $status='';$action='';$jobWorkspace='';$jobRole='';if($job.PSObject.Properties['status']){$status=[string]$job.status}elseif($job.PSObject.Properties['Status']){$status=[string]$job.Status};if($job.PSObject.Properties['action']){$action=[string]$job.action}elseif($job.PSObject.Properties['Action']){$action=[string]$job.Action};if($job.PSObject.Properties['workspace']){$jobWorkspace=[string]$job.workspace};if($job.PSObject.Properties['role']){$jobRole=[string]$job.role}
        if($status -notin @('Succeeded','ReviewRequired') -or $action -notin @('Inventory','SourceInventory','EnrolledInventory') -or $jobRole -cne $Profile.Role -or -not $jobWorkspace -or [IO.Path]::GetFullPath($jobWorkspace) -ine [IO.Path]::GetFullPath($Workspace)){continue}
        foreach($output in @($job.outputs,$job.Outputs)) { foreach($row in @($output)){
            $path='';$hash='';if($row -and $row.PSObject.Properties['Path']){$path=[string]$row.Path};if($row -and $row.PSObject.Properties['SHA256']){$hash=[string]$row.SHA256}
            if(-not $path -or $hash -notmatch '^[a-fA-F0-9]{64}$'){continue}
            $full=[IO.Path]::GetFullPath($path);if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($full) -ine '.json' -or [IO.Path]::GetFileName($full) -notmatch '^inventory-[1-9][0-9]*\.json$' -or -not [IO.File]::Exists($full)){continue}
            try{Assert-WsmNoReparse $full;if((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash -ine $hash){continue};$inventory=Read-WsmTrustedJson $full $hash;Assert-WsmInventory $inventory}catch{continue}
            if($inventory.Source.HostId -cne $Profile.HostId -or $inventory.Source.Fingerprint -ine $Profile.Fingerprint){continue}
            $candidates.Add([pscustomobject]@{Ambiguous=$false;Inventory=$inventory;Path=$full;SHA256=$hash.ToLowerInvariant();JobId=$(if($job.PSObject.Properties['jobId']){[string]$job.jobId}else{''});JobStatus=$status;CompletedUtc=$(if($job.PSObject.Properties['CompletedUtc']){[string]$job.CompletedUtc}else{''})})
        }}
    }
    if(-not $candidates.Count){return $null}
    $unique=@{};foreach($candidate in $candidates){$unique[($candidate.Path.ToLowerInvariant()+'|'+$candidate.SHA256)]=$candidate};$rows=@($unique.Values)
    if($PreferredJobId){$preferred=@($rows|Where-Object JobId -CEQ $PreferredJobId);if($preferred.Count -eq 1){return $preferred[0]}}
    if($PreferredHash){$preferred=@($rows|Where-Object SHA256 -CEQ $PreferredHash);if($preferred.Count -eq 1){return $preferred[0]}}
    if($rows.Count -eq 1){return $rows[0]}
    [pscustomobject]@{Ambiguous=$true;Candidates=@($rows|ForEach-Object {[pscustomobject]@{path=$_.Path;sha256=$_.SHA256;revision=[int]$_.Inventory.Revision;jobId=$_.JobId;completedUtc=$_.CompletedUtc}})}
}





function Get-WsmWizardStageResultAvailability($Catalog) {
    $scan=$null;$backup=$null;$restore=$null;$result=$null
    if(-not $Catalog){return [pscustomobject]@{scan=$scan;backup=$backup;restore=$restore;hasAny=$false}}
    $stageRows=@();if($Catalog.PSObject.Properties['StageResults']){$stageRows=@($Catalog.StageResults)}
    $boundRows=@($stageRows | Where-Object {try{Test-WsmStageResultCurrent $Catalog $_}catch{$false}})
    $payloadRows=@($boundRows | Where-Object {$_.Stage -cne 'Inventory' -and $_.PSObject.Properties['PayloadGeneration'] -and $_.PSObject.Properties['ManifestHash'] -and [long]$_.PayloadGeneration -ge 1 -and [string]$_.ManifestHash -match '^[a-fA-F0-9]{64}$'})
    $latestGeneration=0L;$currentManifest=''
    if($payloadRows.Count){
        $latestGeneration=[long]($payloadRows | Sort-Object PayloadGeneration -Descending | Select-Object -First 1).PayloadGeneration
        $manifests=@($payloadRows | Where-Object {[long]$_.PayloadGeneration -eq $latestGeneration} | ForEach-Object {([string]$_.ManifestHash).ToLowerInvariant()} | Sort-Object -Unique)
        if($manifests.Count -eq 1){$currentManifest=$manifests[0]}
    }
    # Imported stage records are the existing Manager authority. Use only the
    # newest record per stage and the newest known exact package generation.
    # Source/Target attempt orchestration is separate, not inferred from this view.
    $latestRows=@($boundRows | Group-Object Stage | ForEach-Object {$_.Group | Sort-Object Sequence -Descending | Select-Object -First 1})
    foreach($row in $latestRows){
        $terminal=([string]$row.Status -cin @('Succeeded','Failed','Blocked','ManualEvidenceRequired','RebootRequired','Cancelled','Partial','Deferred','DeferredSoftware','WaitForInstall','BlockedConflict'))
        $current=$terminal
        if($row.Stage -cne 'Inventory'){$current=($terminal -and $currentManifest -and $row.PSObject.Properties['PayloadGeneration'] -and [long]$row.PayloadGeneration -eq $latestGeneration -and $row.PSObject.Properties['ManifestHash'] -and [string]$row.ManifestHash -ieq $currentManifest)}
        $entry=[pscustomobject][ordered]@{status=[string]$row.Status;stage=[string]$row.Stage;runId=[string]$row.RunId;generation=$(if($row.PSObject.Properties['PayloadGeneration']){[long]$row.PayloadGeneration}else{$null});producedUtc=[string]$row.ProducedUtc;current=$current;hasDurableRecord=$true}
        if($row.Stage -ceq 'Inventory' -and $current){$scan=$entry}
        elseif($row.Stage -cin @('Export','FinalDelta') -and $current){if(-not $backup -or [DateTimeOffset]::Parse($entry.producedUtc) -gt [DateTimeOffset]::Parse($backup.producedUtc)){$backup=$entry}}
        elseif($row.Stage -ceq 'Restore' -and $current){if(-not $restore -or [DateTimeOffset]::Parse($entry.producedUtc) -gt [DateTimeOffset]::Parse($restore.producedUtc)){$restore=$entry}}
    }
    [pscustomobject]@{scan=$scan;backup=$backup;restore=$restore;hasAny=([bool]$scan -or [bool]$backup -or [bool]$restore)}
}

function Get-WsmWizardCurrentApprovedPlan([string]$Workspace,[string]$PairId,$Profile,$Catalog,[object[]]$Jobs) {
    if($Profile -and $Profile.Role -in @('Source','Target')){return Get-WsmWizardReceivedApprovedPlan $Workspace $PairId $Profile}
    if(-not $Catalog -or -not $Catalog.Approval -or $Catalog.Approval.Kind -cne 'MigrationPlan'){return $null}
    # Avoid PowerShell's automatic $Matches regex variable: the hash-pattern check
    # below populates it and would otherwise replace this candidate collection.
    $verifiedPlans=New-Object 'System.Collections.Generic.List[object]'
    foreach($job in @($Jobs)){
        $job=ConvertTo-WsmNormalizedJobRecord $job
        if(-not $job -or -not $job.PSObject.Properties['action'] -or [string]$job.action -cne 'ApproveMigration' -or -not $job.PSObject.Properties['status'] -or [string]$job.status -cne 'Succeeded' -or -not $job.PSObject.Properties['workspace'] -or [IO.Path]::GetFullPath([string]$job.workspace) -ine [IO.Path]::GetFullPath($Workspace) -or -not $job.PSObject.Properties['role'] -or [string]$job.role -cne 'Manager' -or -not $job.PSObject.Properties['pairId'] -or [string]$job.pairId -cne $PairId){continue}
        foreach($output in @($job.outputs)){
            if(-not $output -or -not $output.PSObject.Properties['Path'] -or -not $output.PSObject.Properties['SHA256'] -or [string]$output.SHA256 -notmatch '^[a-fA-F0-9]{64}$'){continue}
            try{$path=[IO.Path]::GetFullPath([string]$output.Path);Assert-WsmNoReparse $path;if(-not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine [string]$output.SHA256){continue};$plan=Read-WsmMigrationPlan $path ([string]$output.SHA256);if($plan.PairId -cne $PairId -or $plan.ApprovalId -cne [string]$Catalog.Approval.ApprovalId -or $plan.InventoryHash -ine [string]$Catalog.InventoryHash -or [int]$plan.InventoryRevision -ne [int]$Catalog.InventoryRevision -or [int]$plan.DecisionRevision -ne [int]$Catalog.DecisionRevision -or $plan.Target.HostId -cne [string]$Catalog.Approval.TargetHostId -or $plan.Target.Fingerprint -ine [string]$Catalog.Approval.TargetFingerprint -or [string]$output.SHA256 -ine [string]$Catalog.Approval.Hash){continue};$verifiedPlans.Add([pscustomobject]@{Path=$path;SHA256=([string]$output.SHA256).ToLowerInvariant();Plan=$plan;JobId=[string]$job.jobId})}catch{continue}
        }
    }
    $unique=@{};foreach($match in $verifiedPlans){$unique[($match.SHA256+'|'+$match.Path.ToLowerInvariant())]=$match};if($unique.Count -eq 1){return @($unique.Values)[0]};$null
}

function Get-WsmWizardReceivedPlanRoot([string]$Workspace) {
    Join-Path (Join-Path (Join-Path $Workspace 'workspace-control') 'wizard-materials') 'received-plans'
}

function Get-WsmWizardReceivedApprovedPlan([string]$Workspace,[string]$PairId,$Profile) {
    if(-not $PairId -or -not $Profile -or $Profile.Role -notin @('Source','Target')){return $null}
    $root=[IO.Path]::GetFullPath((Get-WsmWizardReceivedPlanRoot $Workspace));if(-not [IO.Directory]::Exists($root)){return $null};Assert-WsmNoReparse $root
    $receivedPlanMatches=New-Object 'System.Collections.Generic.List[object]'
    foreach($receiptFile in @(Get-ChildItem -LiteralPath $root -Filter ($PairId+'-*.json') -File)){
        if($receiptFile.Name.EndsWith('.plan.json',[StringComparison]::OrdinalIgnoreCase)){continue}
        Assert-WsmNoReparse $receiptFile.FullName;if($receiptFile.Length -gt 1048576){continue}
        try{$receipt=Read-WsmJson $receiptFile.FullName;Assert-WsmEnvelope $receipt 'WizardReceivedMigrationPlan';if($receipt.SchemaVersion -ne 1 -or $receipt.Role -cne $Profile.Role -or $receipt.PairId -cne $PairId -or [string]$receipt.PlanHash -notmatch '^[a-f0-9]{64}$'){continue};$planPath=[IO.Path]::GetFullPath([string]$receipt.PlanPath);if(-not $planPath.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){continue};Assert-WsmNoReparse $planPath;if(-not [IO.File]::Exists($planPath) -or (Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash -ine [string]$receipt.PlanHash){continue};$plan=Read-WsmMigrationPlan $planPath ([string]$receipt.PlanHash);$machine=Get-WsmMachineIdentity;$expected=if($Profile.Role -ceq 'Source'){$plan.Source}else{$plan.Target};if($plan.PairId -cne $PairId -or $plan.ApprovalId -cne [string]$receipt.ApprovalId -or $plan.InventoryHash -ine [string]$receipt.InventoryHash -or [int]$plan.InventoryRevision -ne [int]$receipt.InventoryRevision -or [int]$plan.DecisionRevision -ne [int]$receipt.DecisionRevision -or $plan.ToolFingerprint -ine [string]$receipt.ToolFingerprint -or $expected.HostId -cne $Profile.HostId -or $expected.Fingerprint -ine $Profile.Fingerprint -or $machine.Fingerprint -ine $expected.Fingerprint){continue};$receivedPlanMatches.Add([pscustomobject]@{Path=$planPath;SHA256=[string]$receipt.PlanHash;Plan=$plan;JobId=[string]$receipt.ImportOperationId;ReceiptPath=$receiptFile.FullName})}catch{continue}}
    if($receivedPlanMatches.Count -eq 1){return $receivedPlanMatches[0]};$null
}

function Get-WsmWizardReceivedPlanChoices([string]$Workspace,$Profile) {
    if(-not $Profile -or $Profile.Role -notin @('Source','Target')){return @()}
    $root=[IO.Path]::GetFullPath((Get-WsmWizardReceivedPlanRoot $Workspace));if(-not [IO.Directory]::Exists($root)){return @()};Assert-WsmNoReparse $root
    $rows=New-Object 'System.Collections.Generic.List[object]';$seen=@{}
    foreach($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File)){
        if($file.Name.EndsWith('.plan.json',[StringComparison]::OrdinalIgnoreCase)){continue}
        Assert-WsmNoReparse $file.FullName;if($file.Length -gt 1048576){continue}
        try{$receipt=Read-WsmJson $file.FullName;if(-not $receipt.PSObject.Properties['Kind'] -or $receipt.Kind -cne 'WizardReceivedMigrationPlan'){continue};$pair=[string]$receipt.PairId;if(-not $pair -or $seen.ContainsKey($pair)){continue};$verified=Get-WsmWizardReceivedApprovedPlan $Workspace $pair $Profile;if(-not $verified){continue};$seen[$pair]=$true;$rows.Add([pscustomobject][ordered]@{pairId=$pair;approvalId=[string]$verified.Plan.ApprovalId;planHash=[string]$verified.SHA256;targetName=[string]$verified.Plan.Target.Name;sourceName=[string]$verified.Plan.Source.Name;inventoryRevision=[int]$verified.Plan.InventoryRevision;decisionRevision=[int]$verified.Plan.DecisionRevision;provenance='Verified approved plan file; current local host identity, plan hash, receipt and original tool fingerprint checked.'})}catch{continue}
    }
    @($rows.ToArray())
}

function Get-WsmWizardFileDetailIndex([string]$Workspace,[string]$PairId,[string]$Role,$Profile,[object[]]$Jobs) {
    $index=@{};if(-not $PairId -or $Role -cne 'Source' -or -not $Profile -or $Profile.Role -cne 'Source'){return $index}
    $approved=Get-WsmWizardReceivedApprovedPlan $Workspace $PairId $Profile;if(-not $approved){return $index}
    $items=@{};foreach($item in @($approved.Plan.Items)){if($item.PSObject.Properties['ItemId']){$items[[string]$item.ItemId]=$item}}
    $ownedRoot=Join-Path (Join-Path $Workspace 'workspace-control') 'wizard-file-details';$matchesByItem=@{}
    foreach($job in @($Jobs)){
        $job=ConvertTo-WsmNormalizedJobRecord $job
        if(-not $job -or -not $job.PSObject.Properties['action'] -or [string]$job.action -cne 'InspectWizardFiles' -or -not $job.PSObject.Properties['role'] -or [string]$job.role -cne 'Source' -or -not $job.PSObject.Properties['pairId'] -or [string]$job.pairId -cne $PairId -or -not $job.PSObject.Properties['workspace'] -or [IO.Path]::GetFullPath([string]$job.workspace) -ine [IO.Path]::GetFullPath($Workspace) -or [string]$job.status -notin @('Succeeded','ReviewRequired')){continue}
        foreach($output in @($job.outputs)){
            if(-not $output -or -not $output.PSObject.Properties['Path'] -or -not $output.PSObject.Properties['SHA256'] -or -not $output.PSObject.Properties['ItemId']){continue};$id=[string]$output.ItemId;if(-not $items.ContainsKey($id) -or $items[$id].Decision -cne 'Include' -or $items[$id].MigrationSpec.Adapter -cne 'FileScope'){continue}
            try{$record=Read-WsmWizardFileDetails ([string]$output.Path) ([string]$output.SHA256) $ownedRoot $items[$id];if(-not $matchesByItem.ContainsKey($id)){$matchesByItem[$id]=New-Object 'System.Collections.Generic.List[object]'};$matchesByItem[$id].Add([pscustomobject]@{Record=$record;Job=$job})}catch{continue}
        }
    }
    foreach($id in $matchesByItem.Keys){$ordered=@($matchesByItem[$id]|Sort-Object {if($_.Job.PSObject.Properties['CompletedUtc']){[string]$_.Job.CompletedUtc}else{''}} -Descending);if($ordered.Count){$index[$id]=$ordered[0].Record}}
    $index
}

function Import-WsmWizardApprovedPlan {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][ValidateSet('Source','Target')][string]$Role,[Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedHash,[Parameter(DontShow)][string]$OperationId='',[string]$SourceSnapshotPath='')
    if($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'A separately verified plan SHA256 is required.'}
    if($OperationId){Assert-WsmId $OperationId}
    $profile=Read-WsmOutputProfile $Workspace;if(-not $profile -or $profile.Role -cne $Role){throw 'Received-plan role must match the enrolled workspace.'}
    $sourcePath=[IO.Path]::GetFullPath($Path);Assert-WsmNoReparse $sourcePath;if(-not [IO.File]::Exists($sourcePath) -or (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -ine $ExpectedHash){throw 'Received plan path/hash could not be verified.'}
    $plan=Read-WsmMigrationPlan $sourcePath $ExpectedHash;$local=if($Role -ceq 'Source'){$plan.Source}else{$plan.Target};$machine=Get-WsmMachineIdentity
    if($local.HostId -cne $profile.HostId -or $local.Fingerprint -ine $profile.Fingerprint -or $machine.Fingerprint -ine $local.Fingerprint){throw 'Received approved plan is bound to a different local host identity.'}
    $root=[IO.Path]::GetFullPath((Get-WsmWizardReceivedPlanRoot $Workspace));$hash=$ExpectedHash.ToLowerInvariant();$planPath=Join-Path $root ($plan.PairId+'-'+$hash+'.plan.json');$receiptPath=Join-Path $root ($plan.PairId+'-'+$hash+'.json')
    $snapshotStatus='NotRequired';$snapshotNextStep='';$snapshotAttachment='';$snapshotDestination=''
    if($plan.PSObject.Properties['Assistive'] -and $plan.Assistive.PSObject.Properties['ContractVersion'] -and $plan.Assistive.ContractVersion -eq 2){
        $attachmentName=[IO.Path]::GetFileName($sourcePath)+'.source-snapshot.json'
        $candidate=if($SourceSnapshotPath){[IO.Path]::GetFullPath($SourceSnapshotPath)}else{[IO.Path]::GetFullPath($sourcePath+'.source-snapshot.json')}
        if($SourceSnapshotPath -and -not [IO.File]::Exists($candidate)){throw 'The supplied source snapshot attachment does not exist.'}
        if([IO.File]::Exists($candidate)){
            Assert-WsmNoReparse $candidate
            if((New-Object IO.FileInfo($candidate)).Length -gt 128MB){throw 'Source snapshot attachment exceeds 128 MiB.'}
            if((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ine [string]$plan.Assistive.SourceSnapshotHash){throw 'Source snapshot attachment does not match the approved source snapshot hash.'}
            $snapshotRef=$plan.Assistive.DiscoveryAuthority.SourceSnapshotReference;Assert-WsmAssistiveReference $snapshotRef 'Approved source snapshot'
            $pairsRoot=[IO.Path]::GetFullPath((Join-Path $Workspace 'pairs')).TrimEnd('\')+'\'
            $snapshotDestination=[IO.Path]::GetFullPath((Join-Path (Join-Path $Workspace 'pairs') ([string]$snapshotRef.Reference).Replace('/','\')))
            if(-not $snapshotDestination.StartsWith($pairsRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Approved source snapshot reference escapes the Source pairs directory.'}
            $snapshotAttachment=$candidate;$snapshotStatus='Imported'
        }else{$snapshotStatus='Missing';$snapshotNextStep=('請把 Manager 交付的 '+$attachmentName+' 放在計畫檔旁後重新匯入。')}
    }
    if($planPath.Length -gt 239 -or $receiptPath.Length -gt 239){throw 'This WorkRoot is too long to safely store the received plan and its verification record. Choose a shorter fixed WorkRoot and enroll that existing profile explicitly; the wizard will not move workspace data.'}
    if(-not [IO.Directory]::Exists($root)){[void][IO.Directory]::CreateDirectory($root);Protect-WsmDirectory $root};Assert-WsmNoReparse $root
    Invoke-WsmLocked $Workspace {
        if($snapshotAttachment){
            $destinationDirectory=[IO.Path]::GetDirectoryName($snapshotDestination);$pairsDirectory=[IO.Path]::GetFullPath((Join-Path $Workspace 'pairs')).TrimEnd('\')
            if([IO.File]::Exists($snapshotDestination)){Assert-WsmNoReparse $snapshotDestination;if((Get-FileHash -LiteralPath $snapshotDestination -Algorithm SHA256).Hash -ine [string]$plan.Assistive.SourceSnapshotHash){throw 'A different source snapshot already exists at the approved reference; preserve it for reconciliation.'}}
            else{
                $levels=New-Object 'System.Collections.Generic.List[string]';$cursor=$destinationDirectory.TrimEnd('\');while($cursor.Length -gt $pairsDirectory.Length -and $cursor.StartsWith($pairsDirectory,[StringComparison]::OrdinalIgnoreCase)){$levels.Insert(0,$cursor);$cursor=[IO.Path]::GetDirectoryName($cursor)}
                [void](New-WsmOutputOwnedDirectory $pairsDirectory);foreach($level in $levels){[void](New-WsmOutputOwnedDirectory $level)}
                $temporary=$snapshotDestination+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
                try{[IO.File]::Copy($snapshotAttachment,$temporary,$false);if((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ine [string]$plan.Assistive.SourceSnapshotHash){throw 'Source snapshot changed while it was being registered.'};[IO.File]::Move($temporary,$snapshotDestination)}finally{if([IO.File]::Exists($temporary)){try{[IO.File]::Delete($temporary)}catch{}}}
            }
        }
        if([IO.File]::Exists($planPath)){Assert-WsmNoReparse $planPath;if((Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash -ine $hash){throw 'A received plan with this identity was changed; preserve it for reconciliation.'}}
        else{[IO.File]::Copy($sourcePath,$planPath,$false);if((Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash -ine $hash){throw 'Received plan changed while it was being registered.'}}
        if([IO.File]::Exists($receiptPath)){$receipt=Read-WsmJson $receiptPath;if($receipt.Kind -cne 'WizardReceivedMigrationPlan' -or $receipt.PlanHash -ine $hash -or $receipt.PairId -cne $plan.PairId -or $receipt.Role -cne $Role){throw 'A conflicting received-plan reference already exists.'}}
        else{$receipt=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='WizardReceivedMigrationPlan';Role=$Role;PairId=$plan.PairId;PlanPath=[IO.Path]::GetFullPath($planPath);PlanHash=$hash;ApprovalId=$plan.ApprovalId;InventoryHash=$plan.InventoryHash;InventoryRevision=[int]$plan.InventoryRevision;DecisionRevision=[int]$plan.DecisionRevision;ToolFingerprint=[string]$plan.ToolFingerprint;SourceHostId=[string]$plan.Source.HostId;SourceFingerprint=[string]$plan.Source.Fingerprint;TargetHostId=[string]$plan.Target.HostId;TargetFingerprint=[string]$plan.Target.Fingerprint;ImportedUtc=(Get-WsmUtc);ImportOperationId=$OperationId};Write-WsmJson $receiptPath $receipt}
        if($OperationId -and -not $receipt.ImportOperationId){$receipt.ImportOperationId=$OperationId;Write-WsmJson $receiptPath $receipt}
        # Register the trusted pair material in this role-bound OutputProfile so
        # the console can resume it. This is a binding only, never a catalog
        # approval or migration decision.
        [void](Register-WsmOutputPair -WorkRoot $Workspace -Role $Role -PairId $plan.PairId -PlanHash $hash)
        $pairWizardPath=Get-WsmWizardStatePath $Workspace ([string]$plan.PairId) $Role
        if(-not [IO.File]::Exists($pairWizardPath)){
            $firstUsePath=Get-WsmWizardStatePath $Workspace '' $Role
            if([IO.File]::Exists($firstUsePath)){Assert-WsmNoReparse $firstUsePath;$firstUseState=Read-WsmJson $firstUsePath;Assert-WsmWizardState $firstUseState $profile ''|Out-Null}else{$firstUseState=New-WsmWizardState $profile ''}
            $pairWizard=New-WsmWizardState $profile ([string]$plan.PairId)
            $pairWizard.Mode=[string]$firstUseState.Mode;$pairWizard.AutoContinue=[bool]$firstUseState.AutoContinue
            $pairWizard.CurrentStep=if($Role -ceq 'Source'){'backup'}else{'handoff'}
            Assert-WsmWizardState $pairWizard $profile ([string]$plan.PairId)|Out-Null
            Write-WsmJson $pairWizardPath $pairWizard
        }
        [pscustomobject][ordered]@{Status='ImportedVerified';PairId=$plan.PairId;Path=[IO.Path]::GetFullPath($planPath);PlanPath=[IO.Path]::GetFullPath($planPath);SHA256=$hash;ApprovalId=$plan.ApprovalId;InventoryHash=$plan.InventoryHash;InventoryRevision=[int]$plan.InventoryRevision;DecisionRevision=[int]$plan.DecisionRevision;SourceFingerprint=[string]$plan.Source.Fingerprint;TargetFingerprint=[string]$plan.Target.Fingerprint;ImportOperationId=$OperationId;ProductionVerified=$false;SourceSnapshotStatus=$snapshotStatus;SourceSnapshotNextStep=$snapshotNextStep}
    }
}

function Get-WsmWizardProjection {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[string]$PairId='',[Parameter(Mandatory)][ValidateSet('Source','Manager','Target')][string]$Role,[object[]]$Jobs=@())
    if($PairId){Assert-WsmId $PairId}
    $profile=Read-WsmOutputProfile $Workspace
    if(-not $profile){
        $legacy=([IO.File]::Exists((Join-Path $Workspace 'fleet.json')) -or [IO.Directory]::Exists((Join-Path $Workspace 'hosts')))
        if($legacy){
            $fleet=Get-WsmFleet $Workspace;$legacyCatalog=$null;if($PairId){try{$legacyCatalog=Get-WsmCatalog $Workspace $PairId}catch{}}
            $legacyResults=Get-WsmWizardStageResultAvailability $legacyCatalog
            $legacyItems=if($legacyCatalog){@($legacyCatalog.Items)}else{@()}
            return [pscustomobject][ordered]@{schemaVersion=1;kind='WizardProjection';intentRequired=$false;legacy=$true;workflowVersionMismatch=$false;role=$Role;workspaceRole='Legacy';roleMatchesWorkspace=$false;pairId=$PairId;state=$null;revision=0;currentStep='existing';nextStep='existing';mode='CoreWorkflow';catalogAvailable=[bool]$legacyCatalog;groups=@();gates=@([pscustomobject]@{code='LegacyWorkspace';status='Existing';message='這個工作區已有舊版搬移資料。請使用原流程或原版本繼續；精靈不會替既有資料改綁角色。'});actions=@([pscustomobject]@{action='OpenExistingWorkflow';label='開啟既有搬移工作';available=($fleet.Pairs.Count -gt 0);reason='沿用原本的工作區與核心流程；此檢視不會建立新的角色綁定。'});inventoryCandidates=@();inventory=$null;sourceInventory=$null;scan=[pscustomobject]@{status=$(if($legacyCatalog){'Complete'}else{'Unavailable'});hasResult=[bool]$legacyCatalog;itemCount=$legacyItems.Count;incompleteCount=@($legacyItems|Where-Object Status -in @('Partial','Failed','PermissionDenied','Unsupported')).Count};results=$legacyResults;missingFields=@();context=$null;readiness=[pscustomobject]@{roleReady=$false;reason='既有工作區尚未加入角色綁定的精靈；原核心流程仍可使用。';targetBoundApproval=[bool]($legacyCatalog -and $legacyCatalog.Approval -and $legacyCatalog.Approval.Kind -ceq 'MigrationPlan');restoreExplicitConfirmationRequired=$true;activationExplicitConfirmationRequired=$true;productionVerified=$false}}
        }
        return [pscustomobject][ordered]@{schemaVersion=1;kind='WizardProjection';intentRequired=$true;legacy=$false;workflowVersionMismatch=$false;role=$null;workspaceRole=$null;pairId='';state=$null;revision=0;currentStep='start';nextStep='start';mode='ItemByItem';catalogAvailable=$false;sourceInventory=$null;scan=[pscustomobject]@{status='Unavailable';hasResult=$false;itemCount=0;incompleteCount=0};results=[pscustomobject]@{scan=$null;backup=$null;restore=$null;hasAny=$false};groups=@();gates=@();actions=@([pscustomobject]@{action='ChooseIntent';label='選擇這台電腦的用途';available=$true;reason='請先選擇舊主機、新主機或整理搬移資料的電腦；這只會建立對應的本機工作區。'});roleChoices=@([pscustomobject]@{role='Source';value='Source';label='舊主機';description='在舊主機上盤點並準備要交接的搬移資料。'},[pscustomobject]@{role='Target';value='Target';label='新主機';description='在新主機上登錄身分、檢查現況並接收核准的搬移資料。'},[pscustomobject]@{role='Manager';value='Manager';label='整理搬移資料的電腦';description='建立主機搬移工作、審閱項目並完成受控交接。'});missingFields=@();context=$null;readiness=[pscustomobject]@{roleReady=$false;reason='尚未選擇這台電腦的用途。';targetBoundApproval=$false;restoreExplicitConfirmationRequired=$true;activationExplicitConfirmationRequired=$true;productionVerified=$false}}
    }
    $boundRole=[string]$profile.Role;$roleMatches=($boundRole -ceq $Role);$catalog=$null;$inventoryCandidate=$null;$selectionIndex=@{};$resultIndex=@{};$groups=@();$coverage='Unavailable';$sourceInventory=$null;$fileDetailIndex=@{};$gateRows=New-Object 'System.Collections.Generic.List[object]';$actions=New-Object 'System.Collections.Generic.List[object]'
    $state=$null;$stateVersionMismatch=$false;try{$state=Get-WsmWizardState $Workspace $PairId $boundRole}catch{if($_.Exception.Message -match 'Unsupported wizard state schema or version'){$stateVersionMismatch=$true;$state=New-WsmWizardState $profile $PairId}else{throw}}
    if($PairId -and $roleMatches -and $Role -eq 'Source'){$fileDetailIndex=Get-WsmWizardFileDetailIndex $Workspace $PairId $Role $profile $Jobs}
    if($PairId -and $roleMatches -and $Role -eq 'Manager'){$catalog=Get-WsmCatalog $Workspace $PairId;$selection=@();if($catalog.PSObject.Properties['Assistive']){$selection=@((Get-WsmAssistiveCurrentSelections $catalog).Items)};foreach($row in $selection){$selectionIndex[[string]$row.ItemId]=[bool]$row.Selected};foreach($row in @($catalog.Items)){if($row.Decision -ceq 'Include' -and -not $selectionIndex.ContainsKey([string]$row.ItemId)){$selectionIndex[[string]$row.ItemId]=$true}};$latest=Get-WsmLatestStageResult $catalog;if($latest -and $latest.PSObject.Properties['Assistive'] -and $latest.Assistive.PSObject.Properties['ItemResults']){foreach($row in @($latest.Assistive.ItemResults)){$resultIndex[[string]$row.ItemId]=$row}};$confirmed=@{};foreach($row in @($catalog.Items)){if($row.Decision -cne 'Pending'){$confirmed[[string]$row.ItemId]=$true}};$workload=$null;if($catalog.PSObject.Properties['WorkloadDiscovery']){$workload=$catalog.WorkloadDiscovery};$groups=@(Get-WsmWizardGroups @($catalog.Items) $selectionIndex $resultIndex $workload $confirmed);$coverage=if(@($catalog.Items | Where-Object {$_.Status -in @('Partial','Failed','PermissionDenied','Unsupported')}).Count){'Partial'}else{'Complete'} }
    elseif($PairId -and $roleMatches -and $Role -in @('Source','Target')){$receivedPlan=Get-WsmWizardReceivedApprovedPlan $Workspace $PairId $profile;if($receivedPlan){$planItems=@($receivedPlan.Plan.Items);$confirmed=@{};foreach($item in $planItems){$selectionIndex[[string]$item.ItemId]=([string]$item.Decision -ceq 'Include');$confirmed[[string]$item.ItemId]=$true};$groups=@(Get-WsmWizardGroups $planItems $selectionIndex @{} $null $confirmed $fileDetailIndex);$coverage=if(@($planItems|Where-Object Status -in @('Partial','Failed','PermissionDenied','Unsupported')).Count){'Partial'}else{'Complete'}}}
    elseif($Role -in @('Source','Target') -and $roleMatches -and -not $PairId){$inventoryCandidate=Get-WsmWizardInventoryFromJobs $Workspace $profile $Jobs ([string]$state.SourceInventoryHash) ([string]$state.InventoryJobId);if($inventoryCandidate -and -not $inventoryCandidate.Ambiguous){$sourceInventory=$inventoryCandidate.Inventory;$sourceSelection=@{};$sourceConfirmed=@{};if($Role -eq 'Source'){foreach($item in @($sourceInventory.Items)){$blocked=($item.Status -in @('Unsupported','Failed','PermissionDenied') -or $item.Kind -in @('DiscoveryGap','CollectorFailure','UnsupportedCollector'));if($item.PSObject.Properties['Classification'] -and $item.Classification.Disposition -in @('SpecialProduct','Preparation')){$blocked=$true};$sourceSelection[[string]$item.ItemId]=(-not $blocked)};if($state.SourceInventoryHash -ceq $inventoryCandidate.SHA256 -and [long]$state.SourceInventoryRevision -eq [long]$sourceInventory.Revision){foreach($row in @($state.SourceIntent)){$sourceSelection[[string]$row.ItemId]=[bool]$row.Selected;$isConfirmed=$true;if($row.PSObject.Properties['Confirmed']){$isConfirmed=[bool]$row.Confirmed};if($isConfirmed){$sourceConfirmed[[string]$row.ItemId]=$true}}}};$workload=$null;if($sourceInventory.PSObject.Properties['WorkloadDiscovery']){$workload=$sourceInventory.WorkloadDiscovery};$groups=@(Get-WsmWizardGroups @($sourceInventory.Items) $sourceSelection @{} $workload $sourceConfirmed);$coverage=if($inventoryCandidate.JobStatus -eq 'ReviewRequired' -or @($sourceInventory.Items | Where-Object {$_.Status -in @('Partial','Failed','PermissionDenied','Unsupported')}).Count){'Partial'}else{'Complete'}}}
    $availability=Get-WsmWizardStageResultAvailability $catalog
    if($PairId -and $roleMatches -and $Role -ceq 'Source'){$availability.backup=Get-WsmWizardBackupAvailability $Workspace $PairId $profile $Jobs}
    elseif($PairId -and $roleMatches -and $Role -ceq 'Target'){
        # Keep terminal Target results visible without invoking recovery or the
        # live native software scan on a GET. Explicit preview/restore writers
        # still perform the full current-software comparison.
        try{
            $targetContext=Assert-WsmWizardTargetRole $Workspace $PairId
            $targetPackage=Get-WsmWizardTargetPackage $Workspace $PairId $targetContext $Jobs
            $targetSnapshot=Get-WsmWizardTargetSnapshotForRuntime $Workspace $targetContext $Jobs
            $targetDecision=Get-WsmWizardTargetDecisionRecord $Workspace $PairId $targetContext.Received.SHA256
            if($targetDecision){
                $availability.restore=Get-WsmWizardRuntimeTargetRestoreResult $Workspace $PairId $targetContext.Received $targetPackage $targetSnapshot $targetDecision $Jobs
                if(-not $availability.restore){$availability.restore=Get-WsmWizardRuntimeFailedRestore $Workspace $PairId $targetPackage.Package $targetSnapshot $targetDecision $Jobs}
            }
        }catch{}
    }
    $availability.hasAny=([bool]$availability.scan -or [bool]$availability.backup -or [bool]$availability.restore)
    if($sourceInventory){$availability.scan=[pscustomobject]@{status=$(if($coverage -eq 'Partial'){'Partial'}else{'Succeeded'});stage='Inventory';runId=$inventoryCandidate.JobId;generation=[long]$sourceInventory.Revision;producedUtc=[string]$sourceInventory.CreatedUtc;current=$true;hasDurableRecord=$true;source='DurableInventoryJob';inventoryHash=$inventoryCandidate.SHA256;inventoryPath=$inventoryCandidate.Path}}
    elseif($catalog -and -not $availability.scan -and $catalog.PSObject.Properties['InventoryHash'] -and $catalog.InventoryHash){$availability.scan=[pscustomobject]@{status=$(if($coverage -eq 'Partial'){'Partial'}else{'Succeeded'});stage='Inventory';runId='';generation=[long]$catalog.InventoryRevision;producedUtc=[string]$catalog.ImportedUtc;current=$true;hasDurableRecord=$true;source='DurableCatalogInventory';inventoryHash=[string]$catalog.InventoryHash}}
    $roleReady=$true;$roleReason='';$approved=$false;if($profile.Role -cne $Role){$roleReady=$false;$roleReason='這台電腦的用途與目前工作不符。'}
    if(-not $PairId){
        if($Role -eq 'Source'){$actions.Add([pscustomobject]@{action='Inventory';label='掃描這台舊主機';available=$true;reason=$(if($sourceInventory){'已找到與此主機身分相符且由成功盤點作業產生的資料。'}elseif($inventoryCandidate -and $inventoryCandidate.Ambiguous){'有多份有效盤點資料，請先選擇要繼續的那一份。'}else{'尚無可驗證的成功盤點作業。'})});if($sourceInventory -and $state.SourceInventoryHash -ceq $inventoryCandidate.SHA256 -and [long]$state.SourceInventoryRevision -eq [long]$sourceInventory.Revision){$actions.Add([pscustomobject]@{action='SourceCandidateScan';label='探索 C 槽資料候選';available=$true;reason='以目前已驗證的來源盤點為基礎，在本機進行有界唯讀探索；可查看候選、排除與覆蓋缺口，不會建立檔案範圍或核准。'})};if($inventoryCandidate -and $inventoryCandidate.Ambiguous){$actions.Add([pscustomobject]@{action='SelectInventory';label='選擇盤點結果';available=$true;reason='請依時間與資料摘要選擇目前這次要交接的盤點結果。'})};$actions.Add([pscustomobject]@{action='ExportSourceReviewHandoff';label='匯出盤點與已確認選擇';available=[bool]$sourceInventory;reason=$(if($sourceInventory){'產生可安全交給管理端的盤點與審閱意圖資料；不包含核准或備份。'}else{'請先完成本機盤點。'})});$actions.Add([pscustomobject]@{action='ImportApprovedPlan';label='選擇收到的核准計畫';available=$true;reason='需由可信管道取得資料及其獨立 SHA-256。'})}
        elseif($Role -eq 'Manager'){$fleet=Get-WsmFleet $Workspace;$actions.Add([pscustomobject]@{action='ImportSourceReviewHandoff';label='匯入來源盤點與選擇';available=($fleet.Pairs.Count -eq 0);reason=$(if($fleet.Pairs.Count){'選擇要處理的搬移工作。'}else{'需要來源交接檔、獨立 SHA-256 與新主機名稱。'})});$actions.Add([pscustomobject]@{action='ImportInventory';label='匯入舊主機盤點';available=($fleet.Pairs.Count -eq 0);reason=$(if($fleet.Pairs.Count){'選擇要處理的搬移工作。'}else{'需要有效的來源盤點檔及新主機名稱。'})});if($fleet.Pairs.Count -gt 0){foreach($pair in @($fleet.Pairs)){$actions.Add([pscustomobject]@{action='SelectPair';pairId=[string]$pair.PairId;label=([string]$pair.SourceName+' → '+[string]$pair.TargetName);available=$true;reason=''})}}}
        else{$actions.Add([pscustomobject]@{action='Inventory';label='檢查新主機環境';available=$true;reason='盤點不會執行還原或啟用。'});if($inventoryCandidate -and $inventoryCandidate.Ambiguous){$actions.Add([pscustomobject]@{action='SelectInventory';label='選擇盤點結果';available=$true;reason='請選擇與本次作業相符的新主機盤點結果。'})};$actions.Add([pscustomobject]@{action='ExportTargetHandoff';label='匯出新主機交接資料';available=[bool]$sourceInventory;reason='將已註冊新主機身分與本機盤點交给管理端；傳送內容 hash 與獨立可信管道資訊分開核對。'});$actions.Add([pscustomobject]@{action='RegisterTarget';label='保存新主機身分';available=$true;reason='只保存本機可信身分，不會建立遷移核准。'});$actions.Add([pscustomobject]@{action='ImportApprovedPlan';label='選擇收到的核准計畫';available=$true;reason='需由可信管道取得資料及其獨立 SHA-256。'})}
    }else{
        $hasAssistive=($catalog -and $catalog.PSObject.Properties['Assistive']);if($Role -eq 'Manager' -and -not $hasAssistive){$gateRows.Add([pscustomobject]@{code='AssistiveMode';status='Missing';message='需要啟用目前支援的搬移審閱流程。'});$actions.Add([pscustomobject]@{action='AssistiveEnable';label='準備項目審閱';available=[bool]$catalog;reason='使用既有核心建立受控的來源項目選取。'})}
        $targetReady=($Role -eq 'Manager' -and $hasAssistive -and [bool]$catalog.Assistive.TargetCurrent);$approvedPlan=Get-WsmWizardCurrentApprovedPlan $Workspace $PairId $profile $catalog $Jobs;$approved=[bool]$approvedPlan
        $planTargetName='';if($approvedPlan -and $approvedPlan.Plan.Target.PSObject.Properties['Name']){$planTargetName=[string]$approvedPlan.Plan.Target.Name};$targetName=if($catalog){[string]$catalog.TargetName}else{$planTargetName}
        if($Role -eq 'Manager' -and -not $targetName){$gateRows.Add([pscustomobject]@{code='TargetName';status='Missing';message='尚未指定要搬往的新主機。'})}
        if($Role -eq 'Manager' -and -not $targetReady){$gateRows.Add([pscustomobject]@{code='TargetSnapshot';status='Missing';message='需要可信的新主機盤點與身分資料；舊主機自動選取不會建立核准。'})}
        if(-not $approved){$gateRows.Add([pscustomobject]@{code='MigrationApproval';status='Missing';message='需要有效目標身分、完整項目審閱及可驗證的核准計畫材料。'})}
        if($Role -eq 'Manager' -and $catalog -and $catalog.Approval -and $catalog.Approval.Kind -ceq 'MigrationPlan' -and -not $approved){$gateRows[$gateRows.Count-1].status='Stale';$gateRows[$gateRows.Count-1].message='已保存核准標記，但找不到符合目前盤點、決策版本與工具指紋的持久計畫檔；請用建立計畫的原工具版本續作或重新審閱。'}
        if($Role -eq 'Source'){$actions.Add([pscustomobject]@{action='BackupImpactPreview';label='檢查備份與停止寫入影響';available=$approved;reason='只讀目前計畫的 producer、共享影響與原狀態位置；未授權停止來源。'});$actions.Add([pscustomobject]@{action='StartBackup';label='開始已核准備份';available=$approved;reason='只封裝目前核准集合；mutable／NonC 停寫需另外明確授權与可信證據。'})}
        elseif($Role -eq 'Manager'){$handoffRefs=Get-WsmWizardTargetHandoffReferences $Workspace $PairId;$actions.Add([pscustomobject]@{action='BulkPreparationPreview';label='檢查可批次準備的項目';available=($hasAssistive -and -not $approved);reason='先檢查來源預設、必填缺口與不能批次處理的項目；尚未保存任何規格。'});$actions.Add([pscustomobject]@{action='BulkPreparationSave';label='確認並保存批次準備';available=($hasAssistive -and -not $approved);reason='明確提供共用負責人、證據及驗收項目後保存；未知值仍逐項處理，這不是計畫核准。'});$actions.Add([pscustomobject]@{action='GetTargetHandoffPreview';label='核對新主機交接資料';available=$hasAssistive;reason='先選擇收到的交接資料夾，提供獨立可信管道取得的預期 hash，再核對 Source／Target 與盤點摘要。'});$actions.Add([pscustomobject]@{action='CommitTargetHandoff';label='保存已核對的新主機現況';available=($handoffRefs.Previews.Count -gt 0);reason='明確保存當前交接預覽；保留來源盤點，只更新目標事實或受控交接收據。'});$actions.Add([pscustomobject]@{action='PublishComparison';label='更新來源與目標比較';available=$targetReady;reason='只根據目前盤點與選取更新比較，仍不建立核准。'});$actions.Add([pscustomobject]@{action='TargetSnapshot';label='確認新主機現況';available=$true;reason='使用有來源與主機身分綁定的成功盤點資料。'});$actions.Add([pscustomobject]@{action='ApproveMigration';label='審閱並核准搬移計畫';available=$targetReady;reason=$(if($targetReady){'核准仍由既有管理核心閘門執行。'}else{'尚缺可信新主機材料。'})})}
        elseif($Role -eq 'Target' -and $roleMatches){$runtime=Get-WsmWizardRuntimeProjection -Workspace $Workspace -PairId $PairId -Role Target -Jobs $Jobs;if($runtime.status -ceq 'UseExistingWorkflow'){$actions.Add([pscustomobject]@{action='OpenExistingWorkflow';label='開啟既有搬移工作';available=$true;reason='核准計畫採原核心格式，請沿用原流程核對材料與續作。'})};foreach($action in $runtime.actions){$actions.Add([pscustomobject]@{action=[string]$action.id;label=(Get-WsmTextActionLabel ([string]$action.id));available=[bool]$action.available;reason=[string]$action.reason})}}
    }
    $wizardNext='prepare';if($availability.restore){$wizardNext='result'}elseif($availability.backup){$wizardNext=if($availability.backup.PSObject.Properties['hasPackage'] -and $availability.backup.hasPackage){'handoff'}else{'result'}}elseif($availability.scan){$wizardNext=if($Role -eq 'Source'){'review'}else{'prepare'}}
    if($PairId -and $roleMatches -and $Role -ceq 'Source' -and $approved -and -not $availability.backup){$wizardNext='backup'}
    if($PairId -and $roleMatches -and $Role -ceq 'Target' -and $approved -and -not $availability.restore){$wizardNext='restore'}
    $availability.hasAny=([bool]$availability.scan -or [bool]$availability.backup -or [bool]$availability.restore)
    $reviewGroupIndex=-1;if($state.ReviewGroupId){for($i=0;$i -lt $groups.Count;$i++){if($groups[$i].groupId -ceq $state.ReviewGroupId){$reviewGroupIndex=$i;break}}};if($reviewGroupIndex -lt 0 -and $groups.Count){for($i=0;$i -lt $groups.Count;$i++){if(-not $groups[$i].confirmed){$reviewGroupIndex=$i;break}};if($reviewGroupIndex -lt 0){$reviewGroupIndex=0}};$currentGroupId=if($reviewGroupIndex -ge 0){[string]$groups[$reviewGroupIndex].groupId}else{''}
    # A saved marker is only current while every input it describes still matches.
    # Hide stale markers from consumers that use a Completed marker to suppress a
    # retry; the durable state itself remains available for forensic inspection.
    $automaticReviewCurrent=$false;$remainderReviewCurrent=$false
    if($Role -eq 'Source' -and $sourceInventory -and $inventoryCandidate -and -not $inventoryCandidate.Ambiguous){
        $intentHash=Get-WsmHashText ($state.SourceIntent|ConvertTo-Json -Depth 20 -Compress)
        foreach($marker in @('AutomaticReview','RemainderReview')){
            $saved=$null;if($state.PSObject.Properties[$marker]){$saved=$state.$marker}
            if($saved -and [string]$saved.Status -ceq 'Completed' -and [string]$saved.SourceInventoryHash -ceq [string]$inventoryCandidate.SHA256 -and [int]$saved.SourceInventoryRevision -eq [int]$sourceInventory.Revision -and [string]$saved.SourceIntentHash -ceq $intentHash){if($marker -eq 'AutomaticReview'){$automaticReviewCurrent=$true}else{$remainderReviewCurrent=$true}}
        }
    }elseif($Role -eq 'Manager' -and $catalog -and $catalog.PSObject.Properties['Assistive']){
        $selectionNow=Get-WsmAssistiveCurrentSelections $catalog
        foreach($marker in @('AutomaticReview','RemainderReview')){
            $saved=$null;if($state.PSObject.Properties[$marker]){$saved=$state.$marker}
            if($saved -and [string]$saved.Status -ceq 'Completed' -and [string]$saved.InventoryHash -ceq [string]$catalog.InventoryHash -and [int]$saved.InventoryRevision -eq [int]$catalog.InventoryRevision -and [int]$saved.DecisionRevision -eq [int]$catalog.DecisionRevision -and [int]$saved.AssistiveRevision -eq [int]$catalog.Assistive.Revision -and [int]$saved.SelectionRevision -eq [int]$selectionNow.Revision){if($marker -eq 'AutomaticReview'){$automaticReviewCurrent=$true}else{$remainderReviewCurrent=$true}}
        }
    }
    if(-not $stateVersionMismatch){if(-not $automaticReviewCurrent){$state.AutomaticReview=$null};if(-not $remainderReviewCurrent){$state.RemainderReview=$null}}
    if($stateVersionMismatch){$actions.Clear();$gateRows.Add([pscustomobject]@{code='WizardVersion';status='Unsupported';message='本機工作精靈資料來自不同工具版本；請使用建立此工作的原版本繼續，或在原流程檢查工作狀態。'})}
        if($Role -eq 'Manager' -and $catalog -and $catalog.PSObject.Properties['Assistive']){$actions.Add([pscustomobject]@{action='GetPreparationReview';label='編輯已選項目的準備資料';available=(@($catalog.Items|Where-Object Decision -CEQ 'Include').Count -gt 0);reason='選擇項目後填寫必要設定、負責人及證據；保存不等於核准。'})}
    if(-not $roleMatches){$actions.Clear();$gateRows.Add([pscustomobject]@{code='WorkspaceRole';status='Mismatch';message=('這個工作區已設定為 '+$boundRole+'；顯示用途名稱不會改變核心角色或授權。')})}
    [pscustomobject][ordered]@{schemaVersion=1;kind='WizardProjection';intentRequired=$false;legacy=$false;workflowVersionMismatch=$stateVersionMismatch;role=$Role;workspaceRole=$boundRole;roleMatchesWorkspace=$roleMatches;pairId=$PairId;profileId=[string]$profile.ProfileId;hostId=[string]$profile.HostId;state=$(if($stateVersionMismatch){$null}else{$state});revision=$(if($stateVersionMismatch){0}else{[int]$state.Revision});currentStep=$(if($stateVersionMismatch){'existing'}else{[string]$state.CurrentStep});reviewGroupIndex=$reviewGroupIndex;currentGroupId=$currentGroupId;automaticReviewCurrent=$automaticReviewCurrent;remainderReviewCurrent=$remainderReviewCurrent;nextStep=$(if($stateVersionMismatch){'existing'}else{$wizardNext});mode=$(if($stateVersionMismatch){'CoreWorkflow'}else{[string]$state.Mode});catalogAvailable=[bool]$catalog;inventoryCandidates=$(if($inventoryCandidate -and $inventoryCandidate.Ambiguous){@($inventoryCandidate.Candidates)}else{@()});inventory=$(if($inventoryCandidate -and -not $inventoryCandidate.Ambiguous){[pscustomobject]@{path=$inventoryCandidate.Path;sha256=$inventoryCandidate.SHA256;revision=[int]$inventoryCandidate.Inventory.Revision;hostId=[string]$inventoryCandidate.Inventory.Source.HostId;fingerprint=[string]$inventoryCandidate.Inventory.Source.Fingerprint;jobId=[string]$inventoryCandidate.JobId;provenance='Validated successful durable inventory job; path, hash, role and enrolled host binding verified.'}}else{$null});sourceInventory=$(if($Role -eq 'Source' -and $inventoryCandidate -and -not $inventoryCandidate.Ambiguous){[pscustomobject]@{path=$inventoryCandidate.Path;sha256=$inventoryCandidate.SHA256;revision=[int]$sourceInventory.Revision;hostId=[string]$sourceInventory.Source.HostId;fingerprint=[string]$sourceInventory.Source.Fingerprint;jobId=[string]$inventoryCandidate.JobId;provenance='Validated successful durable inventory job; path, hash, role and enrolled host binding verified.'}}else{$null});scan=[pscustomobject]@{status=$coverage;hasResult=[bool]$availability.scan;itemCount=$(if($catalog){@($catalog.Items).Count}elseif($sourceInventory){@($sourceInventory.Items).Count}else{0});incompleteCount=$(if($catalog){@($catalog.Items|Where-Object {$_.Status -in @('Partial','Failed','PermissionDenied','Unsupported')}).Count}elseif($sourceInventory){@($sourceInventory.Items|Where-Object {$_.Status -in @('Partial','Failed','PermissionDenied','Unsupported')}).Count}else{0})};results=$availability;groups=@($groups);gates=@($gateRows.ToArray());actions=@($actions.ToArray());missingFields=@();context=[pscustomobject]@{catalogRevision=$(if($catalog){[int]$catalog.DecisionRevision}else{$null});assistiveRevision=$(if($catalog -and $catalog.PSObject.Properties['Assistive']){[int]$catalog.Assistive.Revision}else{$null});selectionRevision=$(if($catalog -and $catalog.PSObject.Properties['Assistive']){[int](Get-WsmAssistiveCurrentSelections $catalog).Revision}elseif($sourceInventory){[int]$state.Revision}else{$null});sourceSelectionRevision=$(if($catalog -and $catalog.PSObject.Properties['Assistive']){[int]$catalog.Assistive.Selections.Revision}else{$null});inventoryRevision=$(if($catalog){[int]$catalog.InventoryRevision}elseif($sourceInventory){[int]$sourceInventory.Revision}else{$null});inventoryHash=$(if($catalog){[string]$catalog.InventoryHash}elseif($inventoryCandidate -and -not $inventoryCandidate.Ambiguous){[string]$inventoryCandidate.SHA256}else{''})};readiness=[pscustomobject]@{roleReady=($roleReady -and $roleMatches -and -not $stateVersionMismatch);reason=$(if($stateVersionMismatch){'精靈資料版本不同，請使用原工具版本續作。'}elseif($roleMatches){$roleReason}else{'這個工作區已設定為其他用途，請開啟對應工作區。'});targetBoundApproval=$approved;restoreExplicitConfirmationRequired=$true;activationExplicitConfirmationRequired=$true;productionVerified=$false}}
}

function Set-WsmWizardChoice {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[string]$PairId='',[Parameter(Mandatory)][ValidateSet('Source','Manager','Target')][string]$Role,[Parameter(Mandatory)][string]$ItemId,[Parameter(Mandatory)][bool]$Selected,[string]$Reason='', [Parameter(Mandatory)][int]$ExpectedDecisionRevision,[Parameter(Mandatory)][int]$ExpectedSelectionRevision,[object[]]$Jobs=@(),[string]$GroupId='',[int]$ExpectedWizardRevision=-1,[int]$ExpectedAssistiveRevision=-1)
    if(-not $PairId){
        if($Role -cne 'Source'){throw 'A pair must be selected before changing this workspace item.'}
        $profile=Read-WsmOutputProfile $Workspace;$state=Get-WsmWizardState $Workspace '' $Role;$candidate=Get-WsmWizardInventoryFromJobs $Workspace $profile $Jobs ([string]$state.SourceInventoryHash) ([string]$state.InventoryJobId);if(-not $candidate -or $candidate.Ambiguous){throw 'Choose one verified inventory result before saving source choices.'}
        if($ExpectedDecisionRevision -ne [int]$candidate.Inventory.Revision){throw 'Source inventory changed; refresh choices before editing.'}
        $sourceWorkload=$null;if($candidate.Inventory.PSObject.Properties['WorkloadDiscovery']){$sourceWorkload=$candidate.Inventory.WorkloadDiscovery};$groups=Get-WsmWizardGroups @($candidate.Inventory.Items) @{} @{} $sourceWorkload;$group=@($groups|Where-Object groupId -CEQ $GroupId);$ids=@($ItemId);if($GroupId){if($group.Count -ne 1 -or $ItemId -notin $group[0].itemIds){throw 'Choice does not belong to the requested stable group.'};$ids=@($group[0].itemIds)}
        if(-not $Selected -and [string]::IsNullOrWhiteSpace($Reason)){$Reason='使用者選擇不搬移'}
        return Invoke-WsmLocked $Workspace {
            $fresh=Get-WsmWizardInventoryFromJobs $Workspace $profile $Jobs ([string]$state.SourceInventoryHash) ([string]$state.InventoryJobId);if(-not $fresh -or $fresh.Ambiguous -or $fresh.SHA256 -ine $candidate.SHA256 -or [int]$fresh.Inventory.Revision -ne $ExpectedDecisionRevision){throw 'Review changed: source inventory binding.'}
            $wizardPath=Get-WsmWizardStatePath $Workspace '' $Role;if([IO.File]::Exists($wizardPath)){Assert-WsmNoReparse $wizardPath;$state=Read-WsmJson $wizardPath;Assert-WsmWizardState $state $profile '' | Out-Null}else{$state=New-WsmWizardState $profile ''}
            if($ExpectedWizardRevision -lt 0 -or [int]$state.Revision -ne $ExpectedWizardRevision -or $ExpectedSelectionRevision -ne [int]$state.Revision){throw 'Review changed: source wizard selection revision.'}
            $prior=@();if($state.SourceInventoryHash -ceq $fresh.SHA256 -and [long]$state.SourceInventoryRevision -eq [long]$fresh.Inventory.Revision){$prior=@($state.SourceIntent)}
            $map=@{};foreach($row in $prior){$map[[string]$row.ItemId]=$row};foreach($id in $ids){$matches=@($fresh.Inventory.Items|Where-Object ItemId -CEQ $id);if($matches.Count -ne 1){throw 'Unknown source inventory item.'};$item=$matches[0];if($Selected){if($item.Status -cne 'Success' -or $item.Kind -in @('DiscoveryGap','CollectorFailure','UnsupportedCollector')){throw 'Only successfully collected supported items can be included from the Source review.'};if($item.PSObject.Properties['Classification']){$disposition=[string]$item.Classification.Disposition;if($disposition -in @('SpecialProduct','Preparation')){throw 'Special products and target preparation items require a manual process and cannot be included from Source review.'};if($disposition -eq 'Unknown' -and (-not $item.PSObject.Properties['GeneralHostOverride'] -or $item.GeneralHostOverride.Disposition -cne 'Migrate')){throw 'Unknown items require an explicit Migrate disposition before inclusion.'}}};$map[$id]=[pscustomobject]@{ItemId=$id;Selected=$Selected;Reason=$(if($Selected){''}else{$Reason});InventoryHash=$fresh.SHA256;InventoryRevision=[int]$fresh.Inventory.Revision;Confirmed=$true;UpdatedUtc=(Get-WsmUtc)}}
            $state.SourceInventoryHash=$fresh.SHA256;$state.SourceInventoryRevision=[int]$fresh.Inventory.Revision;$state.SourceIntent=[object[]]@($map.Values);$state.Revision=[int]$state.Revision+1;$state.UpdatedUtc=Get-WsmUtc
            Assert-WsmWizardState $state $profile '' | Out-Null;Write-WsmJson $wizardPath $state
            [pscustomobject][ordered]@{Status='Saved';Revision=[int]$state.Revision;SourceIntent=@($state.SourceIntent);SourceInventoryHash=$state.SourceInventoryHash;SourceInventoryRevision=$state.SourceInventoryRevision;AuthoritativeApproval=$false}
        }
    }
    if($Role -cne 'Manager' -and $Role -cne 'Target'){throw 'Only the manager can change source decisions; the target can only change selections within a sealed approval.'}
    # Q4（16.2）：Target 在還原母作業進行中不得變更選取；與 Create-WsmWizardTargetDecisionReceipt 共用同一判定，先於任何修訂檢查與寫入。
    if($Role -ceq 'Target'){Assert-WsmWizardTargetRestoreNotInProgress $Workspace $PairId $Jobs}
    if(-not $Selected -and [string]::IsNullOrWhiteSpace($Reason)){$Reason='使用者選擇不搬移'}
    # Composite counterpart to Set-WsmDecision + Set-WsmAssistiveSelections.
    # Keep their validations and histories in one workspace lock and one catalog write.
    Invoke-WsmLocked $Workspace {
        $catalog=Get-WsmCatalog $Workspace $PairId
        if(-not $catalog.PSObject.Properties['Assistive']){throw 'Enable the supported review workflow before saving item choices.'}
        if($Role -eq 'Target' -and ($ExpectedAssistiveRevision -lt 0 -or [int]$catalog.Assistive.Revision -ne $ExpectedAssistiveRevision)){throw 'Review changed: source Assistive revision.'}
        if([int]$catalog.DecisionRevision -ne $ExpectedDecisionRevision){throw 'Catalog decisions changed; refresh before saving choices.'}
        $current=Get-WsmAssistiveCurrentSelections $catalog
        if([int]$current.Revision -ne $ExpectedSelectionRevision){throw 'Item selections changed; refresh before saving choices.'}
        $profile=Read-WsmOutputProfile $Workspace;$wizardState=$null;$wizardPath=''
        if($ExpectedWizardRevision -ge 0){$wizardPath=Get-WsmWizardStatePath $Workspace $PairId $Role;if([IO.File]::Exists($wizardPath)){Assert-WsmNoReparse $wizardPath;$wizardState=Read-WsmJson $wizardPath;Assert-WsmWizardState $wizardState $profile $PairId | Out-Null}else{$wizardState=New-WsmWizardState $profile $PairId};if([int]$wizardState.Revision -ne $ExpectedWizardRevision){throw 'Review changed: wizard progress revision.'}}
        $workload=$null;if($catalog.PSObject.Properties['WorkloadDiscovery']){$workload=$catalog.WorkloadDiscovery}
        $groups=Get-WsmWizardGroups @($catalog.Items) @{} @{} $workload
        $ids=@($ItemId|Select-Object -Unique)
        if($GroupId){$group=@($groups|Where-Object groupId -CEQ $GroupId);if($group.Count -ne 1 -or $ItemId -notin $group[0].itemIds){throw 'Choice does not belong to the requested stable group.'};if($Selected -and @($group[0].children|Where-Object {-not $_.supported}).Count){throw 'This group contains unsupported or manual-review items; it cannot be included as one group.'};$ids=@($group[0].itemIds)}
        $itemIndex=@{};foreach($item in @($catalog.Items)){$itemIndex[[string]$item.ItemId]=$item}
        $selectionIndex=@{};foreach($row in @($current.Items)){$selectionIndex[[string]$row.ItemId]=$row}
        foreach($id in $ids){if(-not $itemIndex.ContainsKey([string]$id) -or -not $selectionIndex.ContainsKey([string]$id)){throw 'Selection request contains an unknown ItemId.'}}
        $sealed=($catalog.Approval -and $catalog.Approval.PSObject.Properties['Kind'] -and $catalog.Approval.Kind -ceq 'MigrationPlan')
        if($sealed -and $Role -ne 'Target'){throw 'A sealed source plan can only be narrowed by the target workspace.'}
        if(-not $sealed -and $Role -ne 'Manager'){throw 'The target cannot change source decisions before a sealed approval exists.'}
        if($sealed -and $Selected){foreach($id in $ids){$source=@($catalog.Assistive.Selections.Items|Where-Object ItemId -CEQ $id);$item=$itemIndex[[string]$id];if($source.Count -ne 1 -or -not $source[0].Selected -or $item.Decision -cne 'Include'){throw 'Target selection exceeds the sealed source scope; source review and approval are required.'}}}
        $decisionRevision=[int]$catalog.DecisionRevision
        if(-not $sealed){
            $decision=if($Selected){'Include'}else{'Exclude'}
            if($decision -eq 'Include' -and $catalog.PSObject.Properties['GeneralHost']){foreach($id in $ids){$item=$itemIndex[[string]$id];if($item.PSObject.Properties['Classification'] -and $item.Classification.Disposition -eq 'SpecialProduct'){throw 'Special server products and roles cannot be automatically included.'};if($item.PSObject.Properties['Classification'] -and $item.Classification.Disposition -eq 'Preparation'){throw 'Runtime, client, driver and role preparation remains a manual target preparation step.'};if($item.PSObject.Properties['Classification'] -and $item.Classification.Disposition -eq 'Unknown' -and (-not $item.GeneralHostOverride -or $item.GeneralHostOverride.Disposition -cne 'Migrate')){throw 'Unknown objects require an explicit Migrate disposition before Include.'}}}
            $before=New-Object 'System.Collections.Generic.List[object]'
            foreach($id in $ids){$item=$itemIndex[[string]$id];$before.Add([pscustomobject]@{ItemId=$id;Decision=$item.Decision;Reason=$item.Reason;ReviewedBy=$item.ReviewedBy;ReviewedUtc=$item.ReviewedUtc;RuleId=$item.RuleId})}
            foreach($id in $ids){$item=$itemIndex[[string]$id];$item.Decision=$decision;$item.Reason=$(if($Selected){''}else{$Reason});$item.RuleId='';$item.ReviewedBy=[Environment]::UserName;$item.ReviewedUtc=Get-WsmUtc}
            $catalog.DecisionRevision++;$catalog.Approval=$null;if($catalog.SchemaVersion -eq 3){Clear-WsmAssistiveComparison $catalog}
            $catalog.History=@($catalog.History)+@([pscustomobject]@{Actor=(Get-WsmExecutionActor);Revision=$catalog.DecisionRevision;Action='Decision';Before=$before.ToArray();Utc=(Get-WsmUtc)})
            $decisionRevision=[int]$catalog.DecisionRevision
        }
        foreach($id in $ids){$selectionIndex[[string]$id].Selected=$Selected;$selectionIndex[[string]$id].Reason=$(if($Selected){''}else{$Reason});$selectionIndex[[string]$id].UpdatedUtc=Get-WsmUtc}
        $catalog.History=@($catalog.History)+@([pscustomobject]@{Action='AssistiveSelections';AssistiveRevision=([int]$current.Revision+1);ItemIds=@($ids);Selected=$Selected;Reason=$(if($Selected){''}else{$Reason});Actor=(Get-WsmExecutionActor);Utc=(Get-WsmUtc)})
        if($sealed){$current.Revision++;$catalog.Assistive | Add-Member NoteProperty TargetSelections $current -Force;Clear-WsmAssistiveComparison $catalog}
        else{$catalog.Assistive.Selections.Items=@($catalog.Assistive.Selections.Items);$catalog.Assistive.Selections.Revision++;$catalog.Assistive.Revision++;Clear-WsmAssistiveComparison $catalog}
        if($catalog.PSObject.Properties['GeneralHost']){Assert-WsmGeneralHostContract $catalog | Out-Null}
        Assert-WsmAssistiveContract $catalog Catalog | Out-Null
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $catalog
        if($wizardState){
            $confirmed=@($wizardState.ConfirmedItemIds)+@($ids);$wizardState.ConfirmedItemIds=[object[]]@($confirmed|Select-Object -Unique)
            $wizardState.ConfirmationContext=Get-WsmHashText ($catalog.InventoryHash+'|'+$catalog.PairId+'|'+[string]$catalog.InventoryRevision+'|'+[string]$catalog.DecisionRevision+'|'+[string]$catalog.Assistive.Revision)
            $wizardState.ConfirmationSelectionRevision=[int](Get-WsmAssistiveCurrentSelections $catalog).Revision
            $wizardState.Revision=[int]$wizardState.Revision+1;$wizardState.UpdatedUtc=Get-WsmUtc;Assert-WsmWizardState $wizardState $profile $PairId | Out-Null;Write-WsmJson $wizardPath $wizardState
        }
        [pscustomobject][ordered]@{Status='Saved';PairId=$PairId;ItemIds=$ids;Selected=$Selected;Reason=$(if($Selected){''}else{$Reason});DecisionRevision=$decisionRevision;SelectionRevision=[int]$current.Revision;ApprovalPreserved=$sealed;AuthoritativeApproval=$false}
    }
}

function Invoke-WsmWizardAutomaticChoices {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[string]$PairId='',[Parameter(Mandatory)][ValidateSet('Source','Manager')][string]$Role,[Parameter(Mandatory)][int]$ExpectedWizardRevision,[Parameter(Mandatory)][int]$ExpectedDecisionRevision,[Parameter(Mandatory)][int]$ExpectedSelectionRevision,[int]$ExpectedAssistiveRevision=-1,[object[]]$Jobs=@(),[switch]$ConfirmRemainingChoices)
    if($ExpectedWizardRevision -lt 0 -or $ExpectedDecisionRevision -lt 0 -or $ExpectedSelectionRevision -lt 0){throw 'Automatic selection revisions cannot be negative.'}
    $markerName=if($ConfirmRemainingChoices){'RemainderReview'}else{'AutomaticReview'}
    if($Role -eq 'Source'){
        if($PairId){throw 'Source automatic intent is only available before Manager import.'}
        $profile=Read-WsmOutputProfile $Workspace;if(-not $profile -or $profile.Role -cne 'Source'){throw 'Source workspace role is not enrolled.'}
        return Invoke-WsmLocked $Workspace {
            $path=Get-WsmWizardStatePath $Workspace '' Source;if([IO.File]::Exists($path)){Assert-WsmNoReparse $path;$state=Read-WsmJson $path;Assert-WsmWizardState $state $profile '' | Out-Null}else{$state=New-WsmWizardState $profile ''}
            if([int]$state.Revision -ne $ExpectedWizardRevision -or [int]$state.Revision -ne $ExpectedSelectionRevision){throw 'Review changed: source automatic choice revision.'}
            $inventory=Get-WsmWizardInventoryFromJobs $Workspace $profile $Jobs ([string]$state.SourceInventoryHash) ([string]$state.InventoryJobId);if(-not $inventory -or $inventory.Ambiguous -or [int]$inventory.Inventory.Revision -ne $ExpectedDecisionRevision){throw 'Choose one current verified source inventory before automatic selection.'}
            if($state.PSObject.Properties[$markerName] -and $state.$markerName -and $state.$markerName.SourceInventoryHash -ceq $inventory.SHA256 -and [int]$state.$markerName.SourceInventoryRevision -eq [int]$inventory.Inventory.Revision -and $state.$markerName.SourceIntentHash -ceq (Get-WsmHashText ($state.SourceIntent|ConvertTo-Json -Depth 20 -Compress))){throw 'These remaining source choices were already saved for this inventory and intent; refresh before continuing.'}
            $sourceDefaults=@{};foreach($item in @($inventory.Inventory.Items)){$blocked=($item.Status -ne 'Success' -or $item.Kind -in @('DiscoveryGap','CollectorFailure','UnsupportedCollector'));if($item.PSObject.Properties['Classification'] -and $item.Classification.Disposition -in @('SpecialProduct','Preparation')){$blocked=$true};$sourceDefaults[[string]$item.ItemId]=(-not $blocked)}
            $workload=$null;if($inventory.Inventory.PSObject.Properties['WorkloadDiscovery']){$workload=$inventory.Inventory.WorkloadDiscovery};$groups=@(Get-WsmWizardGroups @($inventory.Inventory.Items) $sourceDefaults @{} $workload);$eligible=@{};foreach($group in $groups){foreach($child in @($group.children)){if($child.supported -and $child.status -eq 'Success' -and $child.selected){$eligible[[string]$child.itemId]=$true}}}
            $known=@{};foreach($row in @($state.SourceIntent)){$known[[string]$row.ItemId]=$row}
            $candidates=@{};$alreadyIncluded=@{}
            foreach($id in @($eligible.Keys)){if($known.ContainsKey([string]$id) -and -not $known[[string]$id].Selected){continue};$candidates[[string]$id]=$true;if($known.ContainsKey([string]$id) -and (-not $known[[string]$id].PSObject.Properties['Confirmed'] -or $known[[string]$id].Confirmed)){$alreadyIncluded[[string]$id]=$true}}
            $eligible=Get-WsmWizardAutomaticEligibility @($inventory.Inventory.Items) $candidates $alreadyIncluded
            $applied=New-Object 'System.Collections.Generic.List[string]'
            foreach($item in @($inventory.Inventory.Items)){ $id=[string]$item.ItemId;if($eligible.ContainsKey($id) -and (-not $known.ContainsKey($id) -or $known[$id].Selected)){$known[$id]=[pscustomobject]@{ItemId=$id;Selected=$true;Reason='';InventoryHash=$inventory.SHA256;InventoryRevision=[int]$inventory.Inventory.Revision;Confirmed=$true;UpdatedUtc=(Get-WsmUtc)};$applied.Add($id)} }
            $state.SourceInventoryHash=$inventory.SHA256;$state.SourceInventoryRevision=[int]$inventory.Inventory.Revision;$state.SourceIntent=[object[]]@($known.Values);if(-not $ConfirmRemainingChoices){$state.Mode='Automatic'};$state.Revision++;$state.UpdatedUtc=Get-WsmUtc;$sourceSkipped=@(@($inventory.Inventory.Items|Where-Object { -not $eligible.ContainsKey([string]$_.ItemId)}|ForEach-Object {[string]$_.ItemId}));$state|Add-Member NoteProperty $markerName ([pscustomobject]@{Status='Completed';Mode=$(if($ConfirmRemainingChoices){'ItemByItem'}else{'Automatic'});AppliedItemIds=@($applied.ToArray());AppliedCount=$applied.Count;SkippedItemIds=$sourceSkipped;SkippedCount=$sourceSkipped.Count;SourceInventoryHash=$inventory.SHA256;SourceInventoryRevision=[int]$inventory.Inventory.Revision;SourceIntentHash=(Get-WsmHashText ($state.SourceIntent|ConvertTo-Json -Depth 20 -Compress));WizardRevision=[int]$state.Revision;CompletedUtc=(Get-WsmUtc);AuthoritativeApproval=$false}) -Force;Assert-WsmWizardState $state $profile '' | Out-Null;Write-WsmJson $path $state
            [pscustomobject][ordered]@{Status=$(if($ConfirmRemainingChoices){'SavedRemainder'}else{'SavedIntent'});Mode=$(if($ConfirmRemainingChoices){'ItemByItem'}else{'Automatic'});Revision=[int]$state.Revision;AppliedItemIds=@($applied.ToArray());SkippedItemIds=$sourceSkipped;SourceInventoryHash=$inventory.SHA256;SourceInventoryRevision=[int]$inventory.Inventory.Revision;AuthoritativeApproval=$false}
        }
    }
    if(-not $PairId){throw 'Select a migration pair before applying automatic review choices.'}
    $profile=Read-WsmOutputProfile $Workspace;if(-not $profile -or $profile.Role -cne 'Manager'){throw 'Automatic core decisions require the enrolled Manager workspace.'}
    Invoke-WsmLocked $Workspace {
        $catalog=Get-WsmCatalog $Workspace $PairId;if(-not $catalog.PSObject.Properties['Assistive']){throw 'Enable the supported review workflow before automatic choices.'};if($catalog.Approval -and $catalog.Approval.PSObject.Properties['Kind'] -and $catalog.Approval.Kind -ceq 'MigrationPlan'){throw 'A sealed approved plan cannot be changed by automatic review.'}
        if([int]$catalog.DecisionRevision -ne $ExpectedDecisionRevision -or [int]$catalog.Assistive.Revision -ne $ExpectedAssistiveRevision){throw 'Review changed: catalog or Assistive revision.'}
        $current=Get-WsmAssistiveCurrentSelections $catalog;if([int]$current.Revision -ne $ExpectedSelectionRevision){throw 'Review changed: selection revision.'}
        $wizardPath=Get-WsmWizardStatePath $Workspace $PairId Manager;if([IO.File]::Exists($wizardPath)){Assert-WsmNoReparse $wizardPath;$state=Read-WsmJson $wizardPath;Assert-WsmWizardState $state $profile $PairId | Out-Null}else{$state=New-WsmWizardState $profile $PairId};if([int]$state.Revision -ne $ExpectedWizardRevision){throw 'Review changed: wizard progress revision.'}
        if($state.PSObject.Properties[$markerName] -and $state.$markerName -and [string]$state.$markerName.InventoryHash -ceq [string]$catalog.InventoryHash -and [int]$state.$markerName.InventoryRevision -eq [int]$catalog.InventoryRevision -and [int]$state.$markerName.DecisionRevision -eq [int]$catalog.DecisionRevision -and [int]$state.$markerName.AssistiveRevision -eq [int]$catalog.Assistive.Revision -and [int]$state.$markerName.SelectionRevision -eq [int]$current.Revision){throw 'These choices were already saved for the current catalog; refresh before continuing.'}
        $selectionIndex=@{};foreach($row in @($current.Items)){$selectionIndex[[string]$row.ItemId]=$row};$workload=$null;if($catalog.PSObject.Properties['WorkloadDiscovery']){$workload=$catalog.WorkloadDiscovery};$groups=@(Get-WsmWizardGroups @($catalog.Items) @{} @{} $workload);$supported=@{};foreach($group in $groups){foreach($child in @($group.children)){if($child.supported -and $child.status -eq 'Success'){$supported[[string]$child.itemId]=$true}}}
        $index=@{};foreach($item in @($catalog.Items)){$index[[string]$item.ItemId]=$item}
        $candidates=@{};$alreadyIncluded=@{}
        foreach($item in @($catalog.Items)){
            $id=[string]$item.ItemId
            if($item.Decision -ceq 'Include' -and $item.Present -and $item.Status -ceq 'Success' -and $selectionIndex.ContainsKey($id) -and $selectionIndex[$id].Selected){$alreadyIncluded[$id]=$true}
            if($item.Decision -cne 'Pending' -or -not $supported.ContainsKey($id) -or -not $item.Present -or $item.Status -cne 'Success'){continue}
            if($catalog.PSObject.Properties['GeneralHost'] -and $item.PSObject.Properties['Classification']){$d=[string]$item.Classification.Disposition;if($d -in @('SpecialProduct','Preparation') -or ($d -eq 'Unknown' -and (-not $item.PSObject.Properties['GeneralHostOverride'] -or $item.GeneralHostOverride.Disposition -cne 'Migrate'))){continue}}
            $candidates[$id]=$true
        }
        $eligible=Get-WsmWizardAutomaticEligibility @($catalog.Items) $candidates $alreadyIncluded
        $apply=New-Object 'System.Collections.Generic.List[string]';foreach($id in @($eligible.Keys|Sort-Object)){$apply.Add([string]$id)}
        $before=New-Object 'System.Collections.Generic.List[object]';foreach($id in $apply){$item=$index[$id];$before.Add([pscustomobject]@{ItemId=$id;Decision=$item.Decision;Reason=$item.Reason;ReviewedBy=$item.ReviewedBy;ReviewedUtc=$item.ReviewedUtc;RuleId=$item.RuleId});$item.Decision='Include';$item.Reason='Automatic wizard choice for supported, eligible item';$item.RuleId='';$item.ReviewedBy=[Environment]::UserName;$item.ReviewedUtc=Get-WsmUtc;$selectionIndex[$id].Selected=$true;$selectionIndex[$id].Reason='';$selectionIndex[$id].UpdatedUtc=Get-WsmUtc}
        if($apply.Count){$catalog.DecisionRevision++;$catalog.History=@($catalog.History)+@([pscustomobject]@{Actor=(Get-WsmExecutionActor);Revision=$catalog.DecisionRevision;Action='Decision';Before=$before.ToArray();Utc=(Get-WsmUtc)});$current.Items=@($current.Items);$current.Revision++;$catalog.Assistive.Selections.Items=@($catalog.Assistive.Selections.Items);$catalog.Assistive.Selections.Revision++;Clear-WsmAssistiveComparison $catalog;$catalog.Approval=$null;$catalog.History=@($catalog.History)+@([pscustomobject]@{Action='AssistiveSelections';AssistiveRevision=$catalog.Assistive.Revision+1;ItemIds=@($apply.ToArray());Selected=$true;Reason='Automatic wizard choices';Actor=(Get-WsmExecutionActor);Utc=(Get-WsmUtc)});$catalog.Assistive.Revision++;$state.ConfirmationContext=Get-WsmHashText ($catalog.InventoryHash+'|'+$catalog.PairId+'|'+[string]$catalog.InventoryRevision+'|'+[string]$catalog.DecisionRevision+'|'+[string]$catalog.Assistive.Revision);$state.ConfirmationSelectionRevision=[int](Get-WsmAssistiveCurrentSelections $catalog).Revision;$state.ConfirmedItemIds=[object[]]@(@($catalog.Items|Where-Object {$_.Decision -cne 'Pending'}|ForEach-Object {[string]$_.ItemId}));if($catalog.PSObject.Properties['GeneralHost']){Assert-WsmGeneralHostContract $catalog | Out-Null};Assert-WsmAssistiveContract $catalog Catalog | Out-Null;Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $catalog}
        $skipped=@($catalog.Items|Where-Object {$_.Decision -eq 'Pending' -or ($_.Decision -eq 'Exclude' -and -not $selectionIndex[[string]$_.ItemId].Selected)}|ForEach-Object {[string]$_.ItemId})
        if(-not $ConfirmRemainingChoices){$state.Mode='Automatic'};$state.Revision++;$state.UpdatedUtc=Get-WsmUtc;$state|Add-Member NoteProperty $markerName ([pscustomobject]@{Status='Completed';Mode=$(if($ConfirmRemainingChoices){'ItemByItem'}else{'Automatic'});AppliedItemIds=@($apply.ToArray());AppliedCount=$apply.Count;SkippedItemIds=$skipped;SkippedCount=$skipped.Count;InventoryHash=[string]$catalog.InventoryHash;InventoryRevision=[int]$catalog.InventoryRevision;DecisionRevision=[int]$catalog.DecisionRevision;AssistiveRevision=[int]$catalog.Assistive.Revision;SelectionRevision=[int](Get-WsmAssistiveCurrentSelections $catalog).Revision;WizardRevision=[int]$state.Revision;CompletedUtc=(Get-WsmUtc);AuthoritativeApproval=$false}) -Force;Assert-WsmWizardState $state $profile $PairId | Out-Null;Write-WsmJson $wizardPath $state
        [pscustomobject][ordered]@{Status=$(if($ConfirmRemainingChoices){'SavedRemainder'}else{'Saved'});Mode=$(if($ConfirmRemainingChoices){[string]$state.Mode}else{'Automatic'});Revision=[int]$state.Revision;CatalogRevision=[int]$catalog.DecisionRevision;AssistiveRevision=[int]$catalog.Assistive.Revision;SelectionRevision=[int](Get-WsmAssistiveCurrentSelections $catalog).Revision;AppliedItemIds=@($apply.ToArray());SkippedItemIds=$skipped;AuthoritativeApproval=$false}
    }
}

function Export-WsmWizardSourceReviewHandoff {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(DontShow)][object[]]$Jobs=@())
    $profile=Read-WsmOutputProfile $Workspace;if(-not $profile -or $profile.Role -cne 'Source'){throw 'Source review handoff requires this enrolled workspace to be the Source role.'}
    $state=Get-WsmWizardState $Workspace '' Source;$inventory=Get-WsmWizardInventoryFromJobs $Workspace $profile $Jobs ([string]$state.SourceInventoryHash) ([string]$state.InventoryJobId)
    if(-not $inventory -or $inventory.Ambiguous){throw 'Choose one verified current source inventory before exporting its review handoff.'}
    if($state.SourceInventoryHash -cne $inventory.SHA256 -or [long]$state.SourceInventoryRevision -ne [long]$inventory.Inventory.Revision){throw 'Source review choices are not bound to the current verified inventory.'}
    $bytes=[IO.File]::ReadAllBytes($inventory.Path);if($bytes.Length -gt 67108864){throw 'The source inventory is larger than the 64 MiB handoff limit.'}
    $itemIndex=@{};foreach($item in @($inventory.Inventory.Items)){$itemIndex[[string]$item.ItemId]=$item};$seen=@{};$rows=@(foreach($row in @($state.SourceIntent)){if(-not $row.Confirmed){continue};$id=[string]$row.ItemId;if(-not $itemIndex.ContainsKey($id) -or $seen.ContainsKey($id)){throw 'Saved source review contains an unknown or duplicate item.'};$seen[$id]=$true;$item=$itemIndex[$id];[pscustomobject][ordered]@{ItemId=$id;SettingsHash=[string]$item.SettingsHash;Selected=[bool]$row.Selected;Reason=[string]$row.Reason;Confirmed=$true;InventoryHash=$inventory.SHA256;InventoryRevision=[int]$inventory.Inventory.Revision}})
    $handoff=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='WizardSourceReviewHandoff';Role='Source';SourceHostId=[string]$profile.HostId;SourceFingerprint=[string]$profile.Fingerprint;ToolFingerprint=(Get-WsmToolFingerprint);InventoryRevision=[int]$inventory.Inventory.Revision;InventoryHash=$inventory.SHA256;InventoryBase64=[Convert]::ToBase64String($bytes);SourceIntentHash=(Get-WsmHashText ($state.SourceIntent|ConvertTo-Json -Depth 20 -Compress));Choices=$rows;AuthoritativeApproval=$false;CreatedUtc=(Get-WsmUtc)}
    Assert-WsmEnvelope $handoff 'WizardSourceReviewHandoff';$materials=[IO.Path]::GetFullPath((Join-Path (Join-Path $Workspace 'workspace-control') 'wizard-materials'));[void](New-WsmOutputOwnedDirectory $materials);$root=[IO.Path]::GetFullPath((Join-Path $materials 'source-review-handoffs'));[void](New-WsmOutputOwnedDirectory $root);$path=Join-Path $root ('source-review-'+[Guid]::NewGuid().ToString('N')+'.json');Write-WsmJson $path $handoff;$hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    [pscustomobject][ordered]@{Status='Succeeded';HandoffStatus='Exported';Path=[IO.Path]::GetFullPath($path);SHA256=$hash;SourceInventoryHash=$inventory.SHA256;SourceInventoryRevision=[int]$inventory.Inventory.Revision;SourceIntentHash=$handoff.SourceIntentHash;ConfirmedChoiceCount=$rows.Count;IncludedChoiceCount=@($rows|Where-Object Selected).Count;ExcludedChoiceCount=@($rows|Where-Object {-not $_.Selected}).Count;AuthoritativeApproval=$false;ContentRead=$false}
}

function Import-WsmWizardSourceReviewHandoff {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedHash,[Parameter(Mandatory)][string]$TargetName)
    $profile=Read-WsmOutputProfile $Workspace;if(-not $profile -or $profile.Role -cne 'Manager'){throw 'Source review handoff import requires the enrolled Manager role.'}
    Assert-WsmNoReparse $Path;if((Get-Item -LiteralPath $Path).Length -gt 100663296){throw 'The source review handoff is larger than the 96 MiB limit.'};$handoff=Read-WsmTrustedJson $Path $ExpectedHash;Assert-WsmEnvelope $handoff 'WizardSourceReviewHandoff';Assert-WsmFields $handoff @('SchemaVersion','ToolVersion','Kind','Role','SourceHostId','SourceFingerprint','ToolFingerprint','InventoryRevision','InventoryHash','InventoryBase64','SourceIntentHash','Choices','AuthoritativeApproval','CreatedUtc') @('SchemaVersion','ToolVersion','Kind','Role','SourceHostId','SourceFingerprint','ToolFingerprint','InventoryRevision','InventoryHash','InventoryBase64','SourceIntentHash','Choices','AuthoritativeApproval')
    if($handoff.SchemaVersion -ne 1 -or $handoff.Role -cne 'Source' -or $handoff.AuthoritativeApproval -isnot [bool] -or $handoff.AuthoritativeApproval -or [string]$handoff.ToolFingerprint -ine (Get-WsmToolFingerprint) -or [string]$handoff.InventoryHash -notmatch '^[a-fA-F0-9]{64}$' -or [string]$handoff.SourceFingerprint -notmatch '^[a-fA-F0-9]{64}$' -or [int]$handoff.InventoryRevision -lt 0 -or [string]$handoff.SourceIntentHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'Source review handoff version, release, host or inventory binding is invalid.'}
    try{$bytes=[Convert]::FromBase64String([string]$handoff.InventoryBase64)}catch{throw 'Source review handoff inventory encoding is invalid.'};if($bytes.Length -gt 67108864){throw 'The source inventory is larger than the 64 MiB handoff limit.'};$inventoryHash=Get-WsmHashBytes $bytes;if($inventoryHash -ine [string]$handoff.InventoryHash){throw 'Source review handoff inventory bytes do not match the stated SHA-256.'}
    $inventory=ConvertFrom-WsmJson ([Text.Encoding]::UTF8.GetString($bytes));Assert-WsmInventory $inventory;if([int]$inventory.Revision -ne [int]$handoff.InventoryRevision -or [string]$inventory.Source.HostId -cne [string]$handoff.SourceHostId -or [string]$inventory.Source.Fingerprint -ine [string]$handoff.SourceFingerprint){throw 'Source review handoff inventory host or revision binding is invalid.'}
    $safeChoices=New-Object 'System.Collections.Generic.List[object]';$seen=@{};$itemIndex=@{};foreach($item in @($inventory.Items)){$itemIndex[[string]$item.ItemId]=$item}
    foreach($choice in @($handoff.Choices)){Assert-WsmFields $choice @('ItemId','SettingsHash','Selected','Reason','Confirmed','InventoryHash','InventoryRevision') @('ItemId','SettingsHash','Selected','Reason','Confirmed','InventoryHash','InventoryRevision');$id=[string]$choice.ItemId;if($choice.Selected -isnot [bool] -or $choice.Confirmed -isnot [bool] -or -not $choice.Confirmed -or $seen.ContainsKey($id) -or -not $itemIndex.ContainsKey($id) -or [string]$choice.SettingsHash -ine [string]$itemIndex[$id].SettingsHash -or [string]$choice.InventoryHash -ine $inventoryHash -or [int]$choice.InventoryRevision -ne [int]$inventory.Revision -or [string]$choice.Reason -notmatch '^.{0,512}$' -or (-not $choice.Selected -and [string]::IsNullOrWhiteSpace([string]$choice.Reason))){throw 'A source review choice is not bound to exactly one current inventory item or has no exclusion reason.'};$seen[$id]=$true;$safeChoices.Add([pscustomobject]@{ItemId=$id;SettingsHash=[string]$choice.SettingsHash;Selected=[bool]$choice.Selected;Reason=[string]$choice.Reason;Confirmed=$true;InventoryHash=$inventoryHash;InventoryRevision=[int]$inventory.Revision})}
    $materials=[IO.Path]::GetFullPath((Join-Path (Join-Path $Workspace 'workspace-control') 'wizard-materials'));[void](New-WsmOutputOwnedDirectory $materials);$root=[IO.Path]::GetFullPath((Join-Path $materials 'source-review-imports'));[void](New-WsmOutputOwnedDirectory $root);if(-not [IO.Directory]::Exists($root)){[void][IO.Directory]::CreateDirectory($root)};Assert-WsmNoReparse $root;$destination=Join-Path $root ($inventoryHash.ToLowerInvariant()+'.json');Assert-WsmNoReparse $destination
    if([IO.File]::Exists($destination)){if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ine $inventoryHash){throw 'Imported source inventory content-addressed path has different bytes.'}}else{$tmp=Join-Path $root ('.'+[Guid]::NewGuid().ToString('N')+'.tmp');try{[IO.File]::WriteAllBytes($tmp,$bytes);if((Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash -ine $inventoryHash){throw 'Source inventory bytes changed during handoff import.'};[IO.File]::Move($tmp,$destination)}finally{if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}}}
    $catalog=Import-WsmInventory -Workspace $Workspace -Path $destination -ExpectedHash $inventoryHash -TargetName $TargetName -SourceReviewIntent @($safeChoices.ToArray()) -SourceReviewHandoffHash $ExpectedHash
    $applied=@(foreach($choice in $safeChoices){$item=@($catalog.Items|Where-Object ItemId -CEQ $choice.ItemId);if($item.Count -eq 1 -and $item[0].Decision -ceq $(if($choice.Selected){'Include'}else{'Exclude'})){$choice.ItemId}})
    [pscustomobject][ordered]@{Status='Succeeded';HandoffStatus='Imported';PairId=[string]$catalog.PairId;InventoryHash=$inventoryHash;InventoryRevision=[int]$catalog.InventoryRevision;AppliedChoiceCount=$applied.Count;ImportPath=$destination;SourceIntentHash=[string]$handoff.SourceIntentHash;AuthoritativeApproval=$false;ProductionVerified=$false}
}

function Get-WsmWizardActionDefaults {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[string]$PairId='',[Parameter(Mandatory)][ValidateSet('Source','Manager','Target')][string]$Role,[Parameter(Mandatory)][string]$Action,[object[]]$Jobs=@())
    if($Action -in @('NonCTargetHandoffExport','NonCTargetHandoffPreview','NonCTargetHandoffImport','NonCSourceProofExport','NonCTargetProofExport','NonCProofPreview','NonCProofImport','NonCPreparation','NonCAccountObservation','CreateNonCTransferPlan','ImportNonCTransferPlan','StartNonCTransfer','ImportNonCResult')){return Get-WsmWizardNonCActionDefaults $Workspace $PairId $Role $Action $Jobs}
    if($Role -in @('Source','Target') -and $PairId -and ($Action -ceq 'WizardRuntimeProjection' -or (Get-WsmWizardRuntimeActionContracts).Contains($Action))){return Get-WsmWizardRuntimeActionDefaults $Workspace $PairId $Role $Action $Jobs}
    $projection=Get-WsmWizardProjection $Workspace $PairId $Role $Jobs;$profile=Read-WsmOutputProfile $Workspace;$catalog=$null;if($PairId -and $Role -ceq 'Manager'){$catalog=Get-WsmCatalog $Workspace $PairId}
    if(-not $profile){return [pscustomobject][ordered]@{schemaVersion=1;kind='WizardActionDefaults';action=$Action;requiredRole=$Role;args=[pscustomobject]@{};fields=@();missingFields=@();blocked=$true;blockReason='先選擇這台電腦的用途並建立對應工作區。';roleAvailable=$false;sourceProvenance=$null;context=$null;executionPermission='None; defaults are not approval, restore, activation, or business acceptance.'}}
    $meta=@{
        Inventory=@('SourceOrTarget',@('OutputDirectory'))
        ImportApprovedPlan=@('SourceOrTarget',@('Path','ExpectedHash'))
        SourceCandidateScan=@('Source',@())
        ExportSourceReviewHandoff=@('Source',@())
        ImportSourceReviewHandoff=@('Manager',@('Path','ExpectedHash','TargetName'))
        InspectWizardFiles=@('Source',@('ItemId'))
        ImportInventory=@('Manager',@('Path','ExpectedHash','TargetName'))
        RegisterTarget=@('Target',@('StateDirectory','Path'))
        ExportTargetHandoff=@('Target',@('InventoryPath','OutputDirectory'))
        GetTargetHandoffPreview=@('Manager',@('HandoffDirectory','ExpectedManifestHash','ExpectedAssistiveRevision'))
        CommitTargetHandoff=@('Manager',@('PreviewId'))
        AssistiveEnable=@('Manager',@('ExpectedRevision'))
        TargetSnapshot=@('Manager',@('Path','ExpectedHash','ExpectedRevision'))
        PublishComparison=@('Manager',@('ExpectedRevision'))
        ApproveMigration=@('Manager',@('TargetIdentityPath','TargetIdentityHash','Path','ExpectedRevision','PilotAcknowledgement'))
        GetPreparationReview=@('Manager',@('ItemId'))
        SavePreparationReview=@('Manager',@('ItemId','ReviewHash','Owner','Evidence','Answers'))
        BulkPreparationPreview=@('Manager',@())
        BulkPreparationSave=@('Manager',@('PreviewId','PreviewHash','Owner','Evidence','BusinessChecks','ReviewedSourceDefaults'))
        SpecReview=@('Manager',@('ItemId'))
        SaveSpecReview=@('Manager',@('ItemId','Owner','Evidence','ExpectedRevision'))
        ExportPackage=@('Source',@('PlanPath','ExpectedHash','SourceStateDirectory','OutputDirectory'))
        PackageZip=@('Manager',@('PackagePath','ExpectedHash','OutputPath'))
        EnrolledDelivery=@('Manager',@('PairId','PlanHash','ManifestPath','ExpectedManifestHash','OutputDirectory'))
        RestorePreview=@('Target',@('ManifestPath','ExpectedHash','StateDirectory'))
        Restore=@('Target',@('ManifestPath','ExpectedHash','StateDirectory','Confirmed'))
        Validate=@('Target',@('ManifestPath','ExpectedHash','StateDirectory','ValidationEvidence'))
        Acceptance=@('Target',@('ManifestPath','ExpectedHash','StateDirectory'))
        Cutover=@('Target',@('ManifestPath','ExpectedHash','StateDirectory','CutoverPlanPath','CutoverPlanHash','Acknowledgement'))
    }
    if(-not $meta.ContainsKey($Action)){throw 'Action is outside the curated wizard action list.'}
    $requiredRole=[string]$meta[$Action][0];if($requiredRole -ceq 'SourceOrTarget'){$requiredRole=$Role};$required=@($meta[$Action][1]);$args=[ordered]@{};$sources=@{};$missing=New-Object 'System.Collections.Generic.List[object]';$profileMismatch=$Role -cne $requiredRole
    $catalogRevision=$null;if($catalog){$catalogRevision=[int]$catalog.DecisionRevision};$trustedPlan=$null;if($PairId -and $Role -in @('Source','Target')){$trustedPlan=Get-WsmWizardCurrentApprovedPlan $Workspace $PairId $profile $catalog $Jobs};$itemChoices=@()
    if($Action -eq 'Inventory' -and $Role -in @('Source','Target')){$args.OutputDirectory=Join-Path $Workspace ('hosts\'+$profile.Fingerprint+'\inventory');$args.DeepDiscovery=$true;$args.IncludeSoftwareCatalog=$true;$sources.OutputDirectory='Enrolled local workspace profile';$sources.DeepDiscovery='Supported local deep discovery; read-only';$sources.IncludeSoftwareCatalog='Supported local software inventory; read-only';$required=@()}
    elseif($Action -eq 'ImportInventory' -and $Role -eq 'Manager'){$candidate=Get-WsmWizardInventoryFromJobs $Workspace (Read-WsmOutputProfile $Workspace) $Jobs;if($candidate){$args.Path=$candidate.Path;$args.ExpectedHash=$candidate.SHA256;$sources.Path='Successful durable inventory job; verified path, hash, role and enrolled host';$sources.ExpectedHash='Successful durable inventory job; current bytes rehashed'} }
    elseif($Action -eq 'AssistiveEnable' -and $catalog){$args.ExpectedRevision=$catalogRevision;$sources.ExpectedRevision='Current catalog revision'}
    elseif($Action -eq 'TargetSnapshot' -and $catalog){$args.ExpectedRevision=[int]$catalog.Assistive.Revision;$sources.ExpectedRevision='Current assistive catalog revision'}
    elseif($Action -eq 'PublishComparison' -and $catalog){$args.ExpectedRevision=[int]$catalog.Assistive.Revision;$sources.ExpectedRevision='Current assistive catalog revision'}
    elseif($Action -eq 'BulkPreparationSave' -and $catalog){$references=@(Get-WsmWizardBulkPreparationReferences $Workspace $PairId);if($references.Count -eq 1){$args.PreviewId=$references[0].value;$args.PreviewHash=$references[0].previewHash;$sources.PreviewId='Exactly one current protected preparation preview';$sources.PreviewHash='Verified protected local preview bytes'}else{$missing.Add([pscustomobject]@{name='PreviewId';required=$true;source='ExplicitChoice';reason='先產生並檢查目前批次準備預覽；多份預覽不依檔名代選。';options=$references})}}
    elseif($Action -eq 'ApproveMigration' -and $catalog){$args.ExpectedRevision=$catalogRevision;$sources.ExpectedRevision='Current catalog decision revision';$references=Get-WsmWizardTargetHandoffReferences $Workspace $PairId;if($references.Identity){$args.TargetIdentityPath=$references.Identity.Path;$args.TargetIdentityHash=$references.Identity.SHA256;$sources.TargetIdentityPath='Current Target snapshot and trusted handoff receipt';$sources.TargetIdentityHash='Independently trusted handoff identity hash';$args.Path=Join-Path $Workspace ('workspace-control\approved-plans\plan-'+[Guid]::NewGuid().ToString('N')+'.json');$sources.Path='New owned sealed plan path'}}
    elseif($Action -in @('GetPreparationReview','SavePreparationReview') -and $catalog){$itemChoices=@($catalog.Items|Where-Object {$_.Decision -ceq 'Include'}|ForEach-Object {[pscustomobject]@{value=[string]$_.ItemId;label=([string]$_.Name+' · '+[string]$_.Kind)}});$sources.ItemId='Current included catalog items';if($itemChoices.Count -eq 1){$args.ItemId=[string]$itemChoices[0].value};if($Action -eq 'SavePreparationReview' -and $args.Contains('ItemId')){$review=Get-WsmWizardPreparationReview -Workspace $Workspace -PairId $PairId -ItemId $args.ItemId;$args.ReviewHash=[string]$review.ReviewHash;$args.Answers=@{};$sources.ReviewHash='Current server review bound to this exact item';$sources.Answers='Explicit editable form answers only'}}
    elseif($Action -eq 'SaveSpecReview' -and $catalog){$args.ExpectedRevision=[int]$catalog.DecisionRevision;$sources.ExpectedRevision='Current catalog decision revision';$itemChoices=@($catalog.Items|Where-Object {$_.Decision -ceq 'Include'}|ForEach-Object {[pscustomobject]@{value=[string]$_.ItemId;label=([string]$_.Name+' · '+[string]$_.Kind)}});$sources.ItemId='Current included catalog items';if(-not $itemChoices.Count){$missing.Add([pscustomobject]@{name='ItemId';required=$true;source='Unsupported';reason='目前沒有可審閱的已選項目。';options=@()})}}
    elseif($Action -eq 'InspectWizardFiles' -and $trustedPlan){$itemChoices=@($trustedPlan.Plan.Items|Where-Object {$_.Decision -ceq 'Include' -and $_.MigrationSpec -and $_.MigrationSpec.Adapter -ceq 'FileScope'}|ForEach-Object {[pscustomobject]@{value=[string]$_.ItemId;label=[string]$_.Name}});$sources.ItemId='Verified current approved plan; included reviewed FileScope item';if(-not $itemChoices.Count){$missing.Add([pscustomobject]@{name='ItemId';required=$true;source='Unsupported';reason='目前核准計畫沒有可展開的檔案範圍。'})}}
    elseif($Action -eq 'ExportTargetHandoff' -and $Role -ceq 'Target'){$args.WorkRoot=$Workspace;$sources.WorkRoot='Enrolled Target workspace';if($projection.inventory){$args.InventoryPath=[string]$projection.inventory.path;$sources.InventoryPath='Verified Target inventory job for enrolled physical host'};$args.OutputDirectory=Join-Path $Workspace ('workspace-control\target-handoffs\'+[Guid]::NewGuid().ToString('N'));$sources.OutputDirectory='Fresh owned Target handoff export directory'}
    elseif($Action -eq 'GetTargetHandoffPreview' -and $catalog){$args.ExpectedAssistiveRevision=[int]$catalog.Assistive.Revision;$sources.ExpectedAssistiveRevision='Current Manager Assistive revision';$sources.ExpectedManifestHash='Independent trusted material expectation; not an observed self-hash'}
    elseif($Action -eq 'CommitTargetHandoff' -and $catalog){$references=Get-WsmWizardTargetHandoffReferences $Workspace $PairId;if($references.Previews.Count -eq 1){$args.PreviewId=[string]$references.Previews[0].value;$sources.PreviewId='Exactly one current hash-verified Target handoff preview'}else{$missing.Add([pscustomobject]@{name='PreviewId';required=$true;source='ExplicitChoice';reason='Select a current reviewed Target handoff; ambiguous previews are not chosen by filename.';options=@($references.Previews)})}}
    elseif($Action -eq 'RegisterTarget' -and $Role -eq 'Target'){$stateDir=(Join-Path $Workspace 'pairs');$args.StateDirectory=$stateDir;$args.Path=(Join-Path (Join-Path (Join-Path $Workspace 'targets') $profile.HostId) 'target-identity.json');$sources.StateDirectory='Enrolled target workspace';$sources.Path='Enrolled target identity record'}
    elseif($Action -eq 'ExportPackage' -and $Role -eq 'Source' -and $trustedPlan){$args.PlanPath=$trustedPlan.Path;$args.ExpectedHash=$trustedPlan.SHA256;$args.SourceStateDirectory=(Join-Path $Workspace 'pairs');$sources.PlanPath='Verified received approved plan for this source host';$sources.ExpectedHash='Verified current plan bytes rehashed';$sources.SourceStateDirectory='Registered source OutputPair state root'}
    foreach($field in $required){if($args.Contains($field) -or @($missing|Where-Object name -CEQ $field).Count){continue};$reason='需要可靠材料或使用者提供的值。';if($field -in @('Owner','Evidence','TargetName','Confirmed','ValidationEvidence','Acknowledgement','PilotAcknowledgement')){$reason='這是使用者意圖或外部可信證據，不能由工具代填。'};if($field -in @('ManifestPath','ExpectedHash','PlanPath','ExpectedManifestHash','PackagePath','TargetIdentityPath','TargetIdentityHash','CutoverPlanPath','CutoverPlanHash')){$reason='尚無已驗證且綁定目前配對／世代的持久材料。'};$missing.Add([pscustomobject]@{name=$field;required=$true;source='Missing';reason=$reason;options=@()})}
    $catalogNotRequired=@('Inventory','ImportInventory','ImportSourceReviewHandoff','ExportSourceReviewHandoff','RegisterTarget','ExportTargetHandoff','ImportApprovedPlan','InspectWizardFiles');$needsReceivedPlan=($Action -eq 'InspectWizardFiles' -and -not $trustedPlan);$blocked=$profileMismatch -or (-not $catalog -and $Action -notin $catalogNotRequired -and $Role -ne 'Source') -or $needsReceivedPlan -or $missing.Count -gt 0
    $blockReason='';if($profileMismatch){$blockReason=('此步驟需要 '+$requiredRole+' 用途的工作區。')}elseif($needsReceivedPlan){$blockReason='請先選擇已收到且與本機主機身分相符的核准計畫。'}elseif(-not $catalog -and $Action -notin $catalogNotRequired -and $Role -ne 'Source'){$blockReason='請先選擇有效的搬移工作。'}elseif($missing.Count){$blockReason='仍缺少必須由使用者選擇或可信材料提供的欄位。'}
    [pscustomobject][ordered]@{schemaVersion=1;kind='WizardActionDefaults';action=$Action;requiredRole=$requiredRole;args=[pscustomobject]$args;fields=@(foreach($field in $required){if($args.Contains($field)){[pscustomobject]@{name=$field;required=$true;present=$true;source=$sources[$field];reason='';options=@()}}elseif(@($missing|Where-Object name -CEQ $field).Count){$missingRow=@($missing|Where-Object name -CEQ $field)[0];if($field -ceq 'ItemId'){$missingRow|Add-Member NoteProperty options $itemChoices -Force};$missingRow}else{[pscustomobject]@{name=$field;required=$false;present=$false;source='NotRequired';reason='';options=@()}}});missingFields=@($missing.ToArray());blocked=$blocked;blockReason=$blockReason;roleAvailable=(-not $profileMismatch);sourceProvenance=$(if($projection.sourceInventory){$projection.sourceInventory}else{$null});context=$projection.context;executionPermission='None; defaults are not approval, restore, activation, or business acceptance.'}
}
