function Get-WsmSourceRuntime($Item) {
    if($Item.NaturalKey -match '[*?\[\]\x00-\x1f]'){throw 'Producer name requires a dedicated literal API procedure; wildcard cmdlets are prohibited.'}
    switch($Item.Kind){
        Service {$s=@(Get-CimInstance Win32_Service | Where-Object Name -CEQ $Item.NaturalKey);if($s.Count -ne 1){throw 'Source service absent/ambiguous.'};[pscustomobject]@{Mode=$s[0].StartMode;Running=($s[0].State -eq 'Running')}}
        ScheduledTask {$last=$Item.NaturalKey.LastIndexOf('\');$t=Get-ScheduledTask -TaskName $Item.NaturalKey.Substring($last+1) -TaskPath $Item.NaturalKey.Substring(0,$last+1);[pscustomobject]@{Enabled=[bool]$t.Settings.Enabled;Running=([string]$t.State -eq 'Running')}}
        {$_ -in @('IISPool','IISSite')} {$m=New-WsmIisManager;try{$o=$m.Sites[$Item.NaturalKey];if($Item.Kind -eq 'IISPool'){$o=$m.ApplicationPools[$Item.NaturalKey]};if(-not $o){throw 'Source IIS object absent.'};$auto=$false;if($Item.Kind -eq 'IISPool'){$auto=$o.AutoStart}else{$auto=$o.ServerAutoStart};[pscustomobject]@{AutoStart=[bool]$auto;Running=([string]$o.State -eq 'Started')}}finally{$m.Dispose()}}
    }
}
function Read-WsmSourceAttempt([string]$Path,[string]$Hash,$Plan,[string]$PlanHash) {
    $s=Read-WsmTrustedJson $Path $Hash;Assert-WsmEnvelope $s 'SourceFreezeAttempt'
    if($s.PairId -cne $Plan.PairId -or $s.PlanHash -ine $PlanHash -or $s.SourceFingerprint -cne $Plan.Source.Fingerprint -or $s.ApprovalId -cne $Plan.ApprovalId){throw 'Source recovery attempt plan/machine binding mismatch.'}
    $baseline=Read-WsmTrustedJson $s.BaselinePath $s.BaselineHash;Assert-WsmInventory $baseline;if($baseline.Source.HostId -cne $Plan.Source.HostId){throw 'Source snapshot identity mismatch.'}
    [pscustomobject]@{State=$s;Baseline=$baseline}
}
function Get-WsmSourceOriginallyRunningTasks($Plan,$Attempt) {
    $saved=@{};foreach($record in @($Attempt.State.Items)){if($saved.ContainsKey([string]$record.ItemId)){throw 'Source task recovery attempt contains duplicate runtime records.'};$saved[[string]$record.ItemId]=$record}
    $running=New-Object 'System.Collections.Generic.List[object]'
    foreach($item in $Plan.Items){
        if($item.Decision -ne 'Include' -or $item.Kind -ne 'ScheduledTask' -or $item.MigrationSpec.Adapter -cne 'ScheduledTask'){continue}
        if(-not $saved.ContainsKey([string]$item.ItemId)){throw 'Source scheduled task original runtime baseline is missing.'}
        $record=$saved[[string]$item.ItemId]
        if($record.Kind -cne 'ScheduledTask' -or $record.Name -cne $item.NaturalKey -or -not $record.PSObject.Properties['OriginalRuntime'] -or $record.OriginalRuntime.Running -isnot [bool]){throw 'Source scheduled task original runtime baseline does not match the approved task.'}
        if($record.OriginalRuntime.Running){[void]$running.Add($item)}
    }
    return $running.ToArray()
}
function Assert-WsmSourceUtcEvidence([string]$Value,[string]$Name) {
    $parsed=[DateTimeOffset]::MinValue
    if([string]::IsNullOrWhiteSpace($Value) -or -not [DateTimeOffset]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -or $parsed.Offset -ne [TimeSpan]::Zero){throw ('Task reconciliation '+$Name+' must be an explicit UTC timestamp.')}
}
function Read-WsmSourceTaskReconciliation([string]$Path,[string]$Hash,$Plan,[string]$PlanHash,$Attempt,[string]$AttemptHash,[string]$Owner) {
    $running=@(Get-WsmSourceOriginallyRunningTasks $Plan $Attempt)
    if(-not $Path -and -not $Hash){if($running.Count){throw 'Originally running source tasks require owner-reviewed task reconciliation evidence before any source mutation.'};return $null}
    if(-not $Path -or -not $Hash){throw 'Task reconciliation requires both a trusted JSON path and its independently obtained SHA256.'}
    $proof=Read-WsmTrustedJson $Path $Hash;Assert-WsmEnvelope $proof 'SourceTaskReconciliation'
    Assert-WsmFields $proof @('SchemaVersion','ToolVersion','Kind','PairId','PlanHash','OriginalBaselineHash','SourceAttemptHash','Owner','Utc','Items') @('SchemaVersion','ToolVersion','Kind','PairId','PlanHash','OriginalBaselineHash','SourceAttemptHash','Owner','Utc','Items')
    if($proof.PairId -cne $Plan.PairId -or $proof.PlanHash -ine $PlanHash -or $proof.OriginalBaselineHash -ine $Attempt.State.BaselineHash -or $proof.SourceAttemptHash -ine $AttemptHash -or $proof.Owner -cne $Owner){throw 'Source task reconciliation plan, baseline, attempt, pair or owner binding mismatch.'}
    Assert-WsmSourceUtcEvidence ([string]$proof.Utc) 'UTC'
    $records=@($proof.Items)
    if($records.Count -ne $running.Count){throw 'Source task reconciliation must cover exactly every originally running approved task.'}
    $expected=@{};foreach($item in $running){$expected[[string]$item.ItemId]=$item}
    $seen=@{}
    foreach($record in $records){
        Assert-WsmFields $record @('ItemId','TaskId','Outcome','Owner','Evidence','Utc') @('ItemId','TaskId','Outcome','Owner','Evidence','Utc')
        if(-not $expected.ContainsKey([string]$record.ItemId) -or $seen.ContainsKey([string]$record.ItemId)){throw 'Source task reconciliation has an unknown or duplicate task item.'}
        $item=$expected[[string]$record.ItemId]
        if($record.TaskId -cne $item.NaturalKey -or $record.Owner -cne $Owner -or $record.Outcome -cnotin @('Reconciled','NoPendingWork') -or [string]::IsNullOrWhiteSpace([string]$record.Evidence) -or ([string]$record.Evidence).Length -gt 2048 -or [string]$record.Evidence -match '[\x00-\x1f\x7f]'){throw 'Source task reconciliation item identity, owner, outcome or evidence is invalid.'}
        Assert-WsmSourceUtcEvidence ([string]$record.Utc) 'item UTC'
        $seen[[string]$record.ItemId]=$true
    }
    [pscustomobject]@{Proof=$proof;SHA256=$Hash.ToLowerInvariant();RunningItemIds=@($running | ForEach-Object ItemId)}
}
function Export-WsmSourceTaskReconciliationTemplate {
    [CmdletBinding(SupportsShouldProcess)]param([Parameter(Mandatory)][string]$PlanPath,[Parameter(Mandatory)][string]$ExpectedHash,[Parameter(Mandatory)][string]$SourceAttemptPath,[Parameter(Mandatory)][string]$SourceAttemptHash,[Parameter(Mandatory)][string]$Path)
    $plan=Read-WsmMigrationPlan $PlanPath $ExpectedHash
    Assert-WsmMigrationHost (Get-WsmMachineIdentity) $plan.Source.Fingerprint
    Assert-WsmSourceWorkspaceSeparation $plan $Path
    $attempt=Read-WsmSourceAttempt $SourceAttemptPath $SourceAttemptHash $plan $ExpectedHash
    $running=@(Get-WsmSourceOriginallyRunningTasks $plan $attempt)
    $rows=@(foreach($item in $running){[pscustomobject][ordered]@{ItemId=$item.ItemId;TaskId=$item.NaturalKey;Outcome='ReviewRequired';Owner='';Evidence='';Utc=''}})
    $template=[pscustomobject][ordered]@{
        SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SourceTaskReconciliation';PairId=$plan.PairId;PlanHash=$ExpectedHash.ToLowerInvariant();OriginalBaselineHash=$attempt.State.BaselineHash.ToLowerInvariant();SourceAttemptHash=$SourceAttemptHash.ToLowerInvariant();Owner='';Utc='';Items=$rows
    }
    $fullPath=[IO.Path]::GetFullPath($Path)
    if([IO.File]::Exists($fullPath) -or [IO.Directory]::Exists($fullPath)){throw 'Task reconciliation template output already exists; preserve it and choose a new path.'}
    if(-not $PSCmdlet.ShouldProcess($fullPath,'Write owner-review task reconciliation draft')){return}
    Write-WsmJson $fullPath $template
    [pscustomobject]@{Path=$fullPath;SHA256=(Get-FileHash -LiteralPath $fullPath).Hash.ToLowerInvariant();PairId=$plan.PairId;OriginallyRunningTaskCount=$rows.Count;TaskProofRequired=($rows.Count -gt 0);Draft=$true;OwnerReviewRequired=$true;ResumeReady=$false;SourceTaskProcessStateRestored=$false}
}
function Assert-WsmSourceTaskRuntimePreconditions($Plan,$Attempt) {
    $saved=@{};foreach($record in @($Attempt.State.Items)){$saved[[string]$record.ItemId]=$record}
    foreach($item in $Plan.Items){
        if($item.Decision -ne 'Include' -or $item.Kind -ne 'ScheduledTask' -or $item.MigrationSpec.Adapter -cne 'ScheduledTask'){continue}
        $record=$saved[[string]$item.ItemId]
        if(-not $record.OriginalRuntime.Running -and (Get-WsmSourceRuntime $item).Running){throw ('Source task is unexpectedly running; owner reconciliation is required before resume: '+$item.NaturalKey)}
    }
}
function Assert-WsmSourceRecoveryBaseline($Plan,$Baseline,$Current) {
    $original=@{};$actual=@{};foreach($i in $Baseline.Items){$original[$i.ItemId]=$i};foreach($i in $Current.Items){$actual[$i.ItemId]=$i};$changes=@();foreach($i in $Plan.Items){if($i.Decision -eq 'Include' -and $i.Kind -eq 'Share' -and $i.MigrationSpec.Adapter -eq 'SmbShare'){$changes+=@([pscustomobject]@{ItemId=$i.ItemId;Kind='Share';Name=$i.NaturalKey;State='Quiesced'})}}
    foreach($i in $Plan.Items){if($i.Decision -eq 'Include' -and $i.Kind -in @('Service','ScheduledTask','IISPool','IISSite') -and $i.MigrationSpec.Adapter -ceq $i.Kind -and $actual.ContainsKey($i.ItemId) -and $original.ContainsKey($i.ItemId) -and $actual[$i.ItemId].SettingsHash -cne $original[$i.ItemId].SettingsHash){$state='Stopped';if($i.Kind -eq 'Service'){$state='DisabledStopped'}elseif($i.Kind -eq 'ScheduledTask'){$state='Disabled'};$changes+=@([pscustomobject]@{ItemId=$i.ItemId;Kind=$i.Kind;Name=$i.NaturalKey;State=$state})}}
    foreach($i in $Plan.Items){if($i.Decision -ne 'Include' -or $i.Kind -eq 'ManualItem'){continue};if(-not $original.ContainsKey($i.ItemId) -or $original[$i.ItemId].SettingsHash -cne $i.SettingsHash -or -not $actual.ContainsKey($i.ItemId)){throw 'Source original approved snapshot is incomplete or changed.'};Assert-WsmQuiescenceChange $original[$i.ItemId] $actual[$i.ItemId] $changes}
}
function Invoke-WsmSourceFreezeWorkflow {
    [CmdletBinding(SupportsShouldProcess)]param([string]$PlanPath,[string]$ExpectedHash,[string]$Path,[string]$Owner,[string]$Evidence,[Parameter(Mandatory)][string]$Acknowledgement,[switch]$SourceIdentityReleased,[string]$ReleaseEvidence,[ValidateRange(1,48)][int]$ValidHours=4,[Parameter(Mandatory)][string]$SourceStateDirectory,[string]$PreviousFreezePath,[string]$PreviousFreezeHash,[string]$PreviousAttemptPath,[string]$PreviousAttemptHash)
    $p=Read-WsmMigrationPlan $PlanPath $ExpectedHash;Assert-WsmMigrationHost (Get-WsmMachineIdentity) $p.Source.Fingerprint
    Assert-WsmSourceWorkspaceSeparation $p $SourceStateDirectory
    Assert-WsmSourceWorkspaceSeparation $p $Path
    if($Acknowledgement -cne 'OWNER-CONFIRMED-QUIESCENCE' -or -not $Owner -or -not $Evidence -or ($SourceIdentityReleased -and -not $ReleaseEvidence)){throw 'Freeze owner/quiescence/release evidence required.'}
    $args=@{PlanPath=$PlanPath;ExpectedHash=$ExpectedHash;Path=$Path;Owner=$Owner;Evidence=$Evidence;Acknowledgement=$Acknowledgement;SourceIdentityReleased=$SourceIdentityReleased;ReleaseEvidence=$ReleaseEvidence;ValidHours=$ValidHours;SourceStateDirectory=$SourceStateDirectory;PreviousFreezePath=$PreviousFreezePath;PreviousFreezeHash=$PreviousFreezeHash}
    if($WhatIfPreference){$args.WhatIf=$true;return (Invoke-WsmFreezeCore @args)}
    if(-not $PSCmdlet.ShouldProcess($p.Source.Name,'Capture recovery baseline and quiesce only approved source producers')){return}
    $prior=$null;if($PreviousAttemptPath){$prior=Read-WsmSourceAttempt $PreviousAttemptPath $PreviousAttemptHash $p $ExpectedHash}
    elseif($PreviousFreezePath){$previous=Read-WsmFreezeRecord $PreviousFreezePath $PreviousFreezeHash $p -AllowExpired;if($previous.PSObject.Properties['SourceAttemptPath']){$prior=Read-WsmSourceAttempt $previous.SourceAttemptPath $previous.SourceAttemptHash $p $ExpectedHash}}
    $fresh=Export-WsmInventory $SourceStateDirectory -DeepDiscovery:($p.Source.PSObject.Properties['DiscoveryDepth'] -and $p.Source.DiscoveryDepth -eq 'Deep');$current=Read-WsmTrustedJson $fresh.Path $fresh.SHA256
    $folder=Join-Path $SourceStateDirectory ('freeze-'+$p.PairId+'-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($folder);Protect-WsmDirectory $folder
    $baseline=$current;if($prior){$baseline=$prior.Baseline;Assert-WsmSourceRecoveryBaseline $p $baseline $current}
    else{Assert-WsmSourceRecoveryBaseline $p $baseline $current}
    $baselinePath=Join-Path $folder 'baseline.json';Write-WsmJson $baselinePath $baseline;$records=@()
    foreach($i in $p.Items){if($i.Decision -eq 'Include' -and $i.Kind -in @('Service','ScheduledTask','IISPool','IISSite') -and $i.MigrationSpec.Adapter -ceq $i.Kind){$runtime=Get-WsmSourceRuntime $i;if($prior){$old=@($prior.State.Items | Where-Object ItemId -CEQ $i.ItemId);if($old.Count -ne 1){throw 'Source recovery runtime snapshot missing.'};$runtime=$old[0].OriginalRuntime};$records+=@([pscustomobject]@{ItemId=$i.ItemId;Kind=$i.Kind;Name=$i.NaturalKey;OriginalRuntime=$runtime})}}
    $shareBaselines=@();foreach($i in $p.Items){if($i.Decision -eq 'Include' -and $i.Kind -eq 'Share' -and $i.MigrationSpec.Adapter -eq 'SmbShare'){if($prior){$savedShare=@($prior.State.ShareBaselines | Where-Object ItemId -CEQ $i.ItemId);if($savedShare.Count -ne 1){throw 'Original share ACL baseline missing from durable source attempt.'};$shareBaselines+=@($savedShare[0])}else{$sourceShare=@($baseline.Items | Where-Object ItemId -CEQ $i.ItemId);if($sourceShare.Count -ne 1){throw 'Source share inventory baseline missing.'};$savedShare=Export-WsmShareQuiescenceBaseline -Plan $p -Item $i -SourceItem $sourceShare[0] -PlanHash $ExpectedHash -Path (Join-Path $folder ($i.ItemId+'.share-baseline.json')) -Owner $Owner -Evidence $Evidence;$shareBaselines+=@([pscustomobject]@{ItemId=$i.ItemId;Path=$savedShare.Path;SHA256=$savedShare.SHA256})}}}
    $priorShareQuiescence=@();if($prior -and $prior.State.PSObject.Properties['ShareQuiescence']){$priorShareQuiescence=@($prior.State.ShareQuiescence)};$attemptPath=Join-Path $folder 'attempt.json';$attempt=[pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SourceFreezeAttempt';PairId=$p.PairId;ApprovalId=$p.ApprovalId;PlanHash=$ExpectedHash;SourceFingerprint=$p.Source.Fingerprint;BaselinePath=$baselinePath;BaselineHash=(Get-FileHash -LiteralPath $baselinePath).Hash;Items=$records;ShareBaselines=$shareBaselines;ShareQuiescence=$priorShareQuiescence;Status='Prepared';Owner=$Owner;Evidence=$Evidence;Utc=(Get-WsmUtc)};Write-WsmJson $attemptPath $attempt
    $args.SourceAttemptPath=$attemptPath;$args.OriginalBaselinePath=$baselinePath;$args.OriginalBaselineHash=$attempt.BaselineHash
    if($prior){$proof=[pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SourceFreeze';FreezeId=[Guid]::NewGuid().ToString();PairId=$p.PairId;ApprovalId=$p.ApprovalId;SourceHostId=$p.Source.HostId;SourceFingerprint=$p.Source.Fingerprint;Owner=$Owner;Evidence=$Evidence;Acknowledgement=$Acknowledgement;ProducedUtc=(Get-WsmUtc);ExpiresUtc=[DateTime]::UtcNow.AddHours($ValidHours).ToString('o');QuiescedSettingsHashes=@(foreach($i in $p.Items){if($i.Decision -eq 'Include' -and $i.Kind -ne 'ManualItem'){$match=@($current.Items | Where-Object ItemId -CEQ $i.ItemId)[0];[pscustomobject]@{ItemId=$i.ItemId;OriginalHash=$i.SettingsHash;QuiescedHash=$match.SettingsHash}}})};$proofPath=Join-Path $folder 'resume-baseline.json';Write-WsmJson $proofPath $proof;$args.PreviousFreezePath=$proofPath;$args.PreviousFreezeHash=(Get-FileHash -LiteralPath $proofPath).Hash}
    try{$attempt.Status='Quiescing';Write-WsmJson $attemptPath $attempt;$result=Invoke-WsmFreezeCore @args;$attempt=Read-WsmJson $attemptPath;$attempt.Status='Frozen';$attempt.Utc=Get-WsmUtc;Write-WsmJson $attemptPath $attempt;$receipt=Read-WsmTrustedJson $result.Path $result.SHA256;$receipt | Add-Member NoteProperty SourceAttemptPath $attemptPath;$receipt | Add-Member NoteProperty SourceAttemptHash (Get-FileHash -LiteralPath $attemptPath).Hash;Write-WsmJson $result.Path $receipt;$result.SHA256=(Get-FileHash -LiteralPath $result.Path).Hash;$result | Add-Member NoteProperty SourceAttemptPath $attemptPath;$result | Add-Member NoteProperty SourceAttemptHash (Get-FileHash -LiteralPath $attemptPath).Hash;$result}
    catch{$attempt=Read-WsmJson $attemptPath;$attempt.Status='Interrupted';$attempt.Utc=Get-WsmUtc;Write-WsmJson $attemptPath $attempt;$error=New-Object InvalidOperationException(('Source freeze interrupted; retain baseline and retry with PreviousAttemptPath '+$attemptPath+' / SHA256 '+(Get-FileHash -LiteralPath $attemptPath).Hash),$_.Exception);throw $error}
}
function Invoke-WsmSourceResumeWorkflow {
    [CmdletBinding(SupportsShouldProcess)]param([string]$PlanPath,[string]$ExpectedHash,[string]$SourceAttemptPath,[string]$SourceAttemptHash,[string]$SourceStateDirectory,[string]$Owner,[string]$OwnershipEvidence,[Parameter(Mandatory)][string]$Acknowledgement,[string]$TaskReconciliationPath,[string]$TaskReconciliationHash)
    $p=Read-WsmMigrationPlan $PlanPath $ExpectedHash;Assert-WsmMigrationHost (Get-WsmMachineIdentity) $p.Source.Fingerprint;if($Acknowledgement -cne ('SOURCE-OWNERSHIP-RESTORED '+$p.PairId) -or -not $Owner -or -not $OwnershipEvidence){throw 'Source restart requires reviewed sole-writer ownership, target stop/data reconciliation and exact pair acknowledgement.'}
    $saved=Read-WsmSourceAttempt $SourceAttemptPath $SourceAttemptHash $p $ExpectedHash
    $taskProof=Read-WsmSourceTaskReconciliation $TaskReconciliationPath $TaskReconciliationHash $p $ExpectedHash $saved $SourceAttemptHash $Owner
    Assert-WsmSourceTaskRuntimePreconditions $p $saved
    $fresh=Export-WsmInventory $SourceStateDirectory -DeepDiscovery:($p.Source.PSObject.Properties['DiscoveryDepth'] -and $p.Source.DiscoveryDepth -eq 'Deep');Assert-WsmSourceRecoveryBaseline $p $saved.Baseline (Read-WsmTrustedJson $fresh.Path $fresh.SHA256)
    $reconciliationHash=$null;if($taskProof){$reconciliationHash=$taskProof.SHA256}
    $preview=[pscustomobject]@{PairId=$p.PairId;Items=$saved.State.Items;Owner=$Owner;OwnershipEvidence=$OwnershipEvidence;ExternalOwnership='Owner-confirmed target stop/reconciliation; no remote interlock';SourceRestartAutomatic=$false;TaskProcessStateRestored=$false;TaskReconciliationSHA256=$reconciliationHash}
    if(-not $PSCmdlet.ShouldProcess($p.Source.Name,'Restore original source startup/runtime only after sole-writer ownership review')){return $preview}
    Invoke-WsmLocked ([IO.Path]::GetDirectoryName($SourceAttemptPath)) {
        $currentAttempt=Read-WsmSourceAttempt $SourceAttemptPath $SourceAttemptHash $p $ExpectedHash
        [void](Read-WsmSourceTaskReconciliation $TaskReconciliationPath $TaskReconciliationHash $p $ExpectedHash $currentAttempt $SourceAttemptHash $Owner)
        Assert-WsmSourceTaskRuntimePreconditions $p $currentAttempt
        $index=@{};foreach($r in $saved.State.Items){$index[$r.ItemId]=$r}
        foreach($i in (Get-WsmRestoreOrder @($p.Items | Where-Object Decision -EQ Include))){if(-not $index.ContainsKey($i.ItemId)){continue};$r=$index[$i.ItemId].OriginalRuntime;switch($i.Kind){
            Service {$mode='Disabled';if($r.Mode -eq 'Auto'){$mode='Automatic'}elseif($r.Mode -eq 'Manual'){$mode='Manual'};Set-Service -Name $i.NaturalKey -StartupType $mode;if($r.Running){Start-Service -Name $i.NaturalKey}else{Stop-Service -Name $i.NaturalKey -ErrorAction Stop};$actual=Get-WsmSourceRuntime $i;if($actual.Mode -cne $r.Mode -or $actual.Running -ne $r.Running){throw 'Source service runtime restoration failed.'}}
        ScheduledTask {$last=$i.NaturalKey.LastIndexOf('\');$name=$i.NaturalKey.Substring($last+1);$folder=$i.NaturalKey.Substring(0,$last+1);if($r.Enabled){Enable-ScheduledTask -TaskName $name -TaskPath $folder | Out-Null}else{Disable-ScheduledTask -TaskName $name -TaskPath $folder | Out-Null};$actualTask=Get-WsmSourceRuntime $i;if($actualTask.Enabled -ne $r.Enabled){throw 'Source task enabled-state restoration failed.'};if(-not $r.Running -and $actualTask.Running){throw 'Source task became unexpectedly running during resume; no task process was started or stopped.'}}
            {$_ -in @('IISPool','IISSite')} {$m=New-WsmIisManager;try{$o=$m.Sites[$i.NaturalKey];if($i.Kind -eq 'IISPool'){$o=$m.ApplicationPools[$i.NaturalKey];$o.AutoStart=$r.AutoStart}else{$o.ServerAutoStart=$r.AutoStart};$m.CommitChanges();if($r.Running){[void]$o.Start()}elseif([string]$o.State -ne 'Stopped'){[void]$o.Stop()}}finally{$m.Dispose()};$actual=Get-WsmSourceRuntime $i;if($actual.AutoStart -ne $r.AutoStart -or $actual.Running -ne $r.Running){throw 'Source IIS runtime restoration failed.'}}
        }}
        $shareBaselines=@();if($saved.State.PSObject.Properties['ShareBaselines']){$shareBaselines=@($saved.State.ShareBaselines)};foreach($shareBaseline in $shareBaselines){$shareItem=@($p.Items | Where-Object ItemId -CEQ $shareBaseline.ItemId);if($shareItem.Count -ne 1){throw 'Saved share baseline has no approved item.'};Restore-WsmShareQuiescence -Plan $p -Item $shareItem[0] -BaselinePath $shareBaseline.Path -BaselineHash $shareBaseline.SHA256 -AttemptPath $SourceAttemptPath -AttemptHash (Get-FileHash -LiteralPath $SourceAttemptPath).Hash -Owner $Owner -OwnershipEvidence $OwnershipEvidence -Acknowledgement $Acknowledgement | Out-Null};$saved.State=Read-WsmJson $SourceAttemptPath;$saved.State.Status='SourceResumed';$saved.State | Add-Member NoteProperty ResumeOwner $Owner -Force;$saved.State | Add-Member NoteProperty OwnershipEvidence $OwnershipEvidence -Force;$saved.State | Add-Member NoteProperty TaskProcessStateRestored $false -Force;$saved.State | Add-Member NoteProperty TaskReconciliationSHA256 $reconciliationHash -Force;$saved.State.Utc=Get-WsmUtc;Write-WsmJson $SourceAttemptPath $saved.State;[pscustomobject]@{PairId=$p.PairId;Status='SourceResumed';Path=$SourceAttemptPath;SHA256=(Get-FileHash -LiteralPath $SourceAttemptPath).Hash;OwnershipManuallyConfirmed=$true;TaskProcessStateRestored=$false;TaskReconciliationSHA256=$reconciliationHash}
    }
}

function Invoke-WsmSourcePairLock([string]$StateDirectory,[string]$PairId,[scriptblock]$Action,[bool]$DryRun) {
    if($DryRun){return (& $Action)}
    $root=Join-Path (Join-Path $StateDirectory 'source-operations') $PairId;Assert-WsmNoReparse $root
    if(-not [IO.Directory]::Exists($root)){[void][IO.Directory]::CreateDirectory($root);Protect-WsmDirectory $root}
    Invoke-WsmLocked $root $Action
}
function Export-WsmFreezeRecord {
    [CmdletBinding(SupportsShouldProcess)]param([string]$PlanPath,[string]$ExpectedHash,[string]$Path,[string]$Owner,[string]$Evidence,[Parameter(Mandatory)][string]$Acknowledgement,[switch]$SourceIdentityReleased,[string]$ReleaseEvidence,[ValidateRange(1,48)][int]$ValidHours=4,[Parameter(Mandatory)][string]$SourceStateDirectory,[string]$PreviousFreezePath,[string]$PreviousFreezeHash,[string]$PreviousAttemptPath,[string]$PreviousAttemptHash)
    $p=Read-WsmMigrationPlan $PlanPath $ExpectedHash;Assert-WsmMigrationHost (Get-WsmMachineIdentity) $p.Source.Fingerprint;Assert-WsmSourceWorkspaceSeparation $p $SourceStateDirectory;$forward=@{};foreach($key in $PSBoundParameters.Keys){$forward[$key]=$PSBoundParameters[$key]}
    Invoke-WsmSourcePairLock $SourceStateDirectory $p.PairId {Invoke-WsmSourceFreezeWorkflow @forward} ([bool]$WhatIfPreference)
}
function Invoke-WsmSourceResume {
    [CmdletBinding(SupportsShouldProcess)]param([string]$PlanPath,[string]$ExpectedHash,[string]$SourceAttemptPath,[string]$SourceAttemptHash,[string]$SourceStateDirectory,[string]$Owner,[string]$OwnershipEvidence,[Parameter(Mandatory)][string]$Acknowledgement,[string]$TaskReconciliationPath,[string]$TaskReconciliationHash)
    $p=Read-WsmMigrationPlan $PlanPath $ExpectedHash;Assert-WsmMigrationHost (Get-WsmMachineIdentity) $p.Source.Fingerprint;Assert-WsmSourceWorkspaceSeparation $p $SourceStateDirectory;$forward=@{};foreach($key in $PSBoundParameters.Keys){$forward[$key]=$PSBoundParameters[$key]}
    Invoke-WsmSourcePairLock $SourceStateDirectory $p.PairId {Invoke-WsmSourceResumeWorkflow @forward} ([bool]$WhatIfPreference)
}
