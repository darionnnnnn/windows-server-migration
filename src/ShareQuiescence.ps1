function Get-WsmShareQuiescenceScope($Plan,$Item) {
    if(-not $Plan -or $Plan.Kind -cne 'MigrationPlan' -or -not $Item -or $Item.Kind -cne 'Share' -or $Item.MigrationSpec.Adapter -cne 'SmbShare' -or $Item.Decision -ne 'Include'){throw 'Share quiescence requires an included approved SMB share migration item.'}
    if($Item.ItemId -notmatch '^[a-f0-9]{64}$' -or $Item.NaturalKey -notmatch '^[^\x00-\x1f*?\[\]]{1,80}$'){throw 'Share item identity/name is invalid.'}
    $spec=$Item.MigrationSpec;$desired=$spec.Desired
    $policy='';$evidence=''
    if($desired.PSObject.Properties['DrainPolicy']){$policy=[string]$desired.DrainPolicy};if($desired.PSObject.Properties['DrainEvidence']){$evidence=[string]$desired.DrainEvidence}
    if(@('BlockNewOpens','CloseReviewedHandles') -cnotcontains $policy -or [string]::IsNullOrWhiteSpace($evidence)){throw 'Reviewed Desired.DrainPolicy and Desired.DrainEvidence are required.'}
    if($desired.Name -cne $Item.NaturalKey){throw 'The source share name must match the approved inventory item identity.'}
    [pscustomobject]@{Name=$Item.NaturalKey;Policy=$policy;Evidence=$evidence;Owner=[string]$spec.Owner}
}
function ConvertTo-WsmShareQuiescencePath([string]$Path) {
    $full=ConvertTo-WsmCanonicalPath $Path
    if($full.Length -eq 3 -and $full[1] -eq ':'){return $full};$full.TrimEnd('\')
}
function Get-WsmShareQuiescenceShare([string]$Name,[string]$ScopeName='') {
    $shares=@(Get-SmbShare -Name $Name -ErrorAction Stop | Where-Object {$_.Name -ceq $Name})
    if($ScopeName){$shares=@($shares | Where-Object {$_.ScopeName -ceq $ScopeName})}
    if($shares.Count -ne 1){throw 'Source share is absent or ambiguous by name/scope.'}
    $shares[0]
}
function Get-WsmShareQuiescenceAces([string]$Name,[string]$ScopeName='') {
    $args=@{Name=$Name;ErrorAction='Stop'};if($ScopeName){$args.ScopeName=$ScopeName}
    @(Get-SmbShareAccess @args | ForEach-Object {
        if($_.AccessControlType -notin @('Allow','Deny') -or $_.AccessRight -notin @('Read','Change','Full') -or ($_.AccessControlType -eq 'Deny' -and $_.AccessRight -ne 'Full')){throw 'Unsupported source share ACE; preserve and use a dedicated procedure.'}
        [pscustomobject][ordered]@{AccountName=[string]$_.AccountName;AccountSid=(Resolve-WsmAccountSid ([string]$_.AccountName));AccessControlType=[string]$_.AccessControlType;AccessRight=[string]$_.AccessRight}
    })
}
function Get-WsmShareQuiescenceAceKeys([object[]]$Aces) {
    @($Aces | ForEach-Object {$sid=$_.AccountSid;if(-not $sid){$sid=Resolve-WsmAccountSid ([string]$_.AccountName)};$sid+'|'+$_.AccessControlType+'|'+$_.AccessRight} | Sort-Object)
}
function Test-WsmShareQuiescenceAcesEqual([object[]]$Left,[object[]]$Right) {
    (($Left | Sort-Object) -join "`n") -ceq (($Right | Sort-Object) -join "`n")
}
function Test-WsmShareQuiescenceWorldDeny([object[]]$Aces) {
    @($Aces | Where-Object {$_.AccountSid -eq 'S-1-1-0' -and $_.AccessControlType -eq 'Deny' -and $_.AccessRight -eq 'Full'}).Count -gt 0
}
function Get-WsmShareQuiescenceHandleScope([string]$ScopeName) {
    if([string]::IsNullOrEmpty($ScopeName)){return '*'}
    $ScopeName
}
function Get-WsmShareQuiescenceSameRootAliases([string]$SharePath,[string]$ShareName,[string]$ScopeName) {
    $root=ConvertTo-WsmShareQuiescencePath $SharePath;$expectedScope=Get-WsmShareQuiescenceHandleScope $ScopeName
    $allShares=@(Get-SmbShare -ErrorAction Stop)
    $selected=New-Object 'System.Collections.Generic.List[object]';$aliases=New-Object 'System.Collections.Generic.List[object]'
    foreach($share in $allShares){
        if(-not $share.PSObject.Properties['Path'] -or [string]::IsNullOrWhiteSpace([string]$share.Path)){continue}
        if((Get-WsmShareQuiescenceHandleScope ([string]$share.ScopeName)) -cne $expectedScope){continue}
        try{$shareRoot=ConvertTo-WsmShareQuiescencePath ([string]$share.Path)}catch{continue}
        if($shareRoot -ine $root){continue}
        if($share.Name -ceq $ShareName){$selected.Add($share)}else{$aliases.Add($share)}
    }
    if($selected.Count -ne 1){throw 'Source share identity could not be uniquely confirmed while checking open-file ownership.'}
    $aliases.ToArray()
}
function Test-WsmShareQuiescenceFileIdentity($Left,$Right) {
    ([UInt64]$Left.FileId -eq [UInt64]$Right.FileId -and [UInt64]$Left.SessionId -eq [UInt64]$Right.SessionId -and [string]$Left.ScopeName -ceq [string]$Right.ScopeName -and [string]$Left.ShareRelativePath -ieq [string]$Right.ShareRelativePath -and [string]$Left.Path -ieq [string]$Right.Path)
}
function Get-WsmShareQuiescenceOpenFiles([string]$SharePath,[string]$ShareName,[string]$ScopeName='') {
    $root=ConvertTo-WsmShareQuiescencePath $SharePath;$rootPrefix=$root;if(-not $rootPrefix.EndsWith('\')){$rootPrefix+='\'};$rows=New-Object 'System.Collections.Generic.List[object]'
    $handleScope=Get-WsmShareQuiescenceHandleScope $ScopeName;$aliases=@(Get-WsmShareQuiescenceSameRootAliases $root $ShareName $ScopeName)
    $fileArgs=@{ScopeName=$handleScope;ErrorAction='Stop'}
    foreach($file in @(Get-SmbOpenFile @fileArgs)){
        if(-not $file.PSObject.Properties['Path'] -or -not $file.PSObject.Properties['ShareRelativePath'] -or -not $file.PSObject.Properties['ScopeName'] -or -not $file.PSObject.Properties['FileId'] -or -not $file.PSObject.Properties['SessionId']){throw 'SMB open-file result lacks path, scope, file, or session identity evidence; cannot prove share ownership.'}
        if(([string]$file.ScopeName) -cne $handleScope){continue}
        $full=ConvertTo-WsmShareQuiescencePath ([string]$file.Path)
        $within=($full -ieq $root -or $full.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase))
        if(-not $within){continue}
        if($full -ieq $root){throw 'An SMB handle points at the share root itself; use a dedicated drain procedure.'}
        $relative=$full.Substring($rootPrefix.Length).Replace('/','\');$reported=([string]$file.ShareRelativePath).TrimStart('\').Replace('/','\')
        $ownershipAmbiguous=($aliases.Count -gt 0)
        if($relative -ine $reported -and -not $ownershipAmbiguous){throw ('SMB file path is inside the configured root but does not prove this exact share scope: '+[string]$file.FileId)}
        $rows.Add([pscustomobject]@{FileId=[UInt64]$file.FileId;SessionId=[UInt64]$file.SessionId;Path=$full;ShareRelativePath=$reported;ClientComputerName=[string]$file.ClientComputerName;ClientUserName=[string]$file.ClientUserName;ShareName=$ShareName;ScopeName=$handleScope;OwnershipAmbiguous=$ownershipAmbiguous;ShareAliases=@($aliases | ForEach-Object {[string]$_.Name})})
    }
    $files=$rows.ToArray();$sessionRows=New-Object 'System.Collections.Generic.List[object]';$sessionArgs=@{ScopeName=$handleScope;ErrorAction='Stop'}
    foreach($session in @(Get-SmbSession @sessionArgs)){
        if(-not $session.PSObject.Properties['ScopeName'] -or -not $session.PSObject.Properties['SessionId']){throw 'SMB session result lacks exact scope/session identity evidence.'}
        if(([string]$session.ScopeName) -cne $handleScope){continue}
        if(@($files | Where-Object {$_.SessionId -eq [UInt64]$session.SessionId -and $_.ScopeName -ceq [string]$session.ScopeName}).Count){$sessionRows.Add([pscustomobject]@{SessionId=[UInt64]$session.SessionId;ClientComputerName=[string]$session.ClientComputerName;ClientUserName=[string]$session.ClientUserName;NumOpens=[int]$session.NumOpens;ScopeName=[string]$session.ScopeName})}
    }
    foreach($file in $files){if(@($sessionRows | Where-Object {$_.SessionId -eq $file.SessionId -and $_.ScopeName -ceq $file.ScopeName}).Count -ne 1){throw 'Open-file handle has no unique matching SMB session in the same scope.'}}
    [pscustomobject]@{Files=$files;Sessions=$sessionRows.ToArray()}
}
function Assert-WsmShareQuiescenceBaseline($Baseline,$Plan,$Item,[string]$ExpectedHash) {
    Assert-WsmEnvelope $Baseline 'SmbShareQuiescenceBaseline';$scope=Get-WsmShareQuiescenceScope $Plan $Item
    if($Baseline.BatchId -cne $Plan.BatchId -or $Baseline.PairId -cne $Plan.PairId -or $Baseline.ApprovalId -cne $Plan.ApprovalId -or $Baseline.PlanHash -ine $ExpectedHash -or $Baseline.SourceHostId -cne $Plan.Source.HostId -or $Baseline.SourceFingerprint -cne $Plan.Source.Fingerprint -or $Baseline.ItemId -cne $Item.ItemId -or $Baseline.ShareName -cne $scope.Name -or $Baseline.SourceSettingsHash -cne $Item.SettingsHash){throw 'Share baseline plan/item/source identity binding mismatch.'}
    if(-not $Baseline.PSObject.Properties['ScopeName'] -or [string]::IsNullOrWhiteSpace([string]$Baseline.Owner) -or [string]::IsNullOrWhiteSpace([string]$Baseline.Evidence) -or [string]::IsNullOrWhiteSpace([string]$Baseline.CapturedUtc) -or [string]$Baseline.Owner -cne $scope.Owner){throw 'Share baseline is missing its reviewed owner/evidence/capture or exact scope binding.'}
    $canonical=ConvertTo-WsmShareQuiescencePath $Baseline.SharePath;if($canonical -cne $Baseline.SharePath){throw 'Share baseline path is not canonical.'}
    foreach($ace in @($Baseline.Access)){if(-not $ace.AccountName -or -not $ace.AccountSid -or -not $ace.AccessControlType -or -not $ace.AccessRight){throw 'Share baseline contains an incomplete ACL row.'};if((Resolve-WsmAccountSid ([string]$ace.AccountName)) -cne [string]$ace.AccountSid){throw 'Share baseline account name/SID binding changed.'}}
    $aces=Get-WsmShareQuiescenceAceKeys $Baseline.Access;if(-not (Test-WsmShareQuiescenceAcesEqual $aces $Baseline.AclKeys) -or [bool]$Baseline.OriginalWorldDeny -ne (Test-WsmShareQuiescenceWorldDeny $Baseline.Access)){throw 'Share baseline ACL digest or original Everyone deny evidence mismatch.'}
    $Baseline
}
function Export-WsmShareQuiescenceBaseline {
    [CmdletBinding()]param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)]$Item,[Parameter(Mandatory)]$SourceItem,[Parameter(Mandatory)][string]$PlanHash,[Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Owner,[Parameter(Mandatory)][string]$Evidence)
    $scope=Get-WsmShareQuiescenceScope $Plan $Item;Assert-WsmMigrationHost (Get-WsmMachineIdentity) $Plan.Source.Fingerprint
    if($SourceItem.ItemId -cne $Item.ItemId -or $SourceItem.SettingsHash -cne $Item.SettingsHash -or $SourceItem.Status -ne 'Success' -or $SourceItem.NaturalKey -cne $scope.Name -or -not $SourceItem.Settings.PSObject.Properties['Definition'] -or -not $SourceItem.Settings.PSObject.Properties['Access']){throw 'A matching successful source inventory item is required to establish the approved share path/ACL.'}
    if(-not $Owner -or -not $Evidence -or $Owner -cne $scope.Owner){throw 'Baseline capture owner must match the approved spec owner and cite evidence.'}
    $definition=$SourceItem.Settings.Definition;$share=Get-WsmShareQuiescenceShare $scope.Name ([string]$definition.ScopeName);$sharePath=ConvertTo-WsmShareQuiescencePath ([string]$share.Path);$expectedPath=ConvertTo-WsmShareQuiescencePath ([string]$definition.Path)
    if($sharePath -ine $expectedPath -or $share.Name -cne $scope.Name){throw 'Live share name/path differs from the approved source inventory; review before freeze.'}
    $access=Get-WsmShareQuiescenceAces $scope.Name ([string]$share.ScopeName);$inventoryAccess=@(foreach($ace in $SourceItem.Settings.Access){[pscustomobject]@{AccountName=[string]$ace.AccountName;AccountSid=(Resolve-WsmAccountSid ([string]$ace.AccountName));AccessControlType=[string]$ace.AccessControlType;AccessRight=[string]$ace.AccessRight}})
    $keys=Get-WsmShareQuiescenceAceKeys $access;$inventoryKeys=Get-WsmShareQuiescenceAceKeys $inventoryAccess;if(-not (Test-WsmShareQuiescenceAcesEqual $keys $inventoryKeys)){throw 'Live share ACL changed since approved inventory.'}
    if($PlanHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'An exact approved plan hash is required for the durable baseline.'}
    $record=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SmbShareQuiescenceBaseline';BatchId=$Plan.BatchId;PairId=$Plan.PairId;ApprovalId=$Plan.ApprovalId;PlanHash=$PlanHash.ToLowerInvariant();SourceHostId=$Plan.Source.HostId;SourceFingerprint=$Plan.Source.Fingerprint;ItemId=$Item.ItemId;SourceSettingsHash=$Item.SettingsHash;ShareName=$scope.Name;ScopeName=[string]$share.ScopeName;SharePath=$sharePath;Access=$access;AclKeys=$keys;OriginalWorldDeny=(Test-WsmShareQuiescenceWorldDeny $access);Owner=$Owner;Evidence=$Evidence;CapturedUtc=(Get-WsmUtc);ProductionVerified=$false}
    Write-WsmJson $Path $record;[pscustomobject]@{Path=[IO.Path]::GetFullPath($Path);SHA256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash;Baseline=$record}
}
function Get-WsmShareQuiescenceAttempt($Plan,$Item,[string]$BaselinePath,[string]$BaselineHash,[string]$AttemptPath,[string]$AttemptHash) {
    $attempt=Read-WsmTrustedJson $AttemptPath $AttemptHash;Assert-WsmEnvelope $attempt 'SourceFreezeAttempt';$baseline=Read-WsmTrustedJson $BaselinePath $BaselineHash;[void](Assert-WsmShareQuiescenceBaseline $baseline $Plan $Item $attempt.PlanHash)
    if($attempt.PairId -cne $Plan.PairId -or $attempt.ApprovalId -cne $Plan.ApprovalId -or $attempt.SourceFingerprint -cne $Plan.Source.Fingerprint){throw 'Source attempt identity mismatch.'}
    if(-not $attempt.PSObject.Properties['ShareBaselines'] -or -not $attempt.PSObject.Properties['ShareQuiescence']){throw 'SourceAttempt lacks durable share-baseline/retry fields.'}
    $entry=@($attempt.ShareBaselines | Where-Object {$_.ItemId -ceq $Item.ItemId -and $_.Path -ceq [IO.Path]::GetFullPath($BaselinePath) -and $_.SHA256 -ieq $BaselineHash});if($entry.Count -ne 1){throw 'Share ACL baseline must be durably referenced by SourceAttempt before changing the share.'}
    $records=@($attempt.ShareQuiescence | Where-Object ItemId -CEQ $Item.ItemId);if($records.Count -gt 1){throw 'Duplicate share quiescence state in SourceAttempt.'};[pscustomobject]@{Attempt=$attempt;Baseline=$baseline;Record=$records}
}
function Save-WsmShareQuiescenceAttempt($Attempt,[string]$AttemptPath) {
    Write-WsmJson $AttemptPath $Attempt;[pscustomobject]@{Attempt=$Attempt;AttemptPath=[IO.Path]::GetFullPath($AttemptPath);AttemptHash=(Get-FileHash -LiteralPath $AttemptPath -Algorithm SHA256).Hash}
}
function Get-WsmShareQuiescenceExpectedKeys($Baseline,[bool]$TemporaryDenyAdded) {
    $expected=@($Baseline.AclKeys);if($TemporaryDenyAdded -and -not $Baseline.OriginalWorldDeny){$expected+=@('S-1-1-0|Deny|Full')};@($expected | Sort-Object)
}
function Assert-WsmShareQuiescenceInventoryDelta($Baseline,$BeforeItem,$AfterItem,$AttemptRecord,[string]$BaselineHash) {
    if($BeforeItem.ItemId -cne $Baseline.ItemId -or $AfterItem.ItemId -cne $Baseline.ItemId -or $BeforeItem.SettingsHash -cne $Baseline.SourceSettingsHash -or $AfterItem.Status -ne 'Success' -or $AttemptRecord.ItemId -cne $Baseline.ItemId -or $AttemptRecord.BaselineHash -ine $BaselineHash -or $AttemptRecord.Status -cne 'Quiesced' -or @($AttemptRecord.OpenFiles).Count){throw 'Source share quiescence inventory proof is incomplete or bound to another baseline.'}
    if(($BeforeItem.Settings.Definition | ConvertTo-Json -Depth 20 -Compress) -cne ($AfterItem.Settings.Definition | ConvertTo-Json -Depth 20 -Compress)){throw 'Share definition changed beyond the explicitly saved ACL drain.'}
    $beforeKeys=Get-WsmShareQuiescenceAceKeys @($BeforeItem.Settings.Access | ForEach-Object {[pscustomobject]@{AccountName=$_.AccountName;AccountSid=(Resolve-WsmAccountSid ([string]$_.AccountName));AccessControlType=$_.AccessControlType;AccessRight=$_.AccessRight}})
    if(-not (Test-WsmShareQuiescenceAcesEqual $beforeKeys $Baseline.AclKeys)){throw 'Pre-freeze source inventory ACL no longer matches the durable share baseline.'}
    $afterKeys=Get-WsmShareQuiescenceAceKeys @($AfterItem.Settings.Access | ForEach-Object {[pscustomobject]@{AccountName=$_.AccountName;AccountSid=(Resolve-WsmAccountSid ([string]$_.AccountName));AccessControlType=$_.AccessControlType;AccessRight=$_.AccessRight}})
    if(-not (Test-WsmShareQuiescenceAcesEqual $afterKeys (Get-WsmShareQuiescenceExpectedKeys $Baseline ([bool]$AttemptRecord.TemporaryDenyAdded)))){throw 'Frozen source share differs from its exact ACL baseline plus the recorded temporary Everyone deny.'}
    [pscustomobject]@{ItemId=$Baseline.ItemId;BaselineHash=$BaselineHash;BeforeSettingsHash=$BeforeItem.SettingsHash;AfterSettingsHash=$AfterItem.SettingsHash;TemporaryDenyAdded=[bool]$AttemptRecord.TemporaryDenyAdded;OnlyApprovedShareDenyChanged=$true;ExistingHandlesDrained=$true;ProductionVerified=$false}
}
function Assert-WsmShareQuiescenceLiveIdentity($Baseline) {
    $share=Get-WsmShareQuiescenceShare $Baseline.ShareName $Baseline.ScopeName;$path=ConvertTo-WsmShareQuiescencePath ([string]$share.Path)
    if($share.Name -cne $Baseline.ShareName -or $share.ScopeName -cne $Baseline.ScopeName -or $path -ine $Baseline.SharePath){throw 'Share name/path/scope drifted after baseline; preserve and reconcile.'};$share
}
function Invoke-WsmShareQuiescence {
    [CmdletBinding()]param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)]$Item,[Parameter(Mandatory)][string]$BaselinePath,[Parameter(Mandatory)][string]$BaselineHash,[Parameter(Mandatory)][string]$AttemptPath,[Parameter(Mandatory)][string]$AttemptHash)
    $scope=Get-WsmShareQuiescenceScope $Plan $Item;Assert-WsmMigrationHost (Get-WsmMachineIdentity) $Plan.Source.Fingerprint;$saved=Get-WsmShareQuiescenceAttempt $Plan $Item $BaselinePath $BaselineHash $AttemptPath $AttemptHash;$attempt=$saved.Attempt;$baseline=$saved.Baseline;$share=Assert-WsmShareQuiescenceLiveIdentity $baseline
    $current=Get-WsmShareQuiescenceAces $baseline.ShareName $baseline.ScopeName;$currentKeys=Get-WsmShareQuiescenceAceKeys $current;$prior=@($saved.Record);$temporary=$false;if($prior.Count){$temporary=[bool]$prior[0].TemporaryDenyAdded}
    $expected=Get-WsmShareQuiescenceExpectedKeys $baseline $temporary
    if(-not (Test-WsmShareQuiescenceAcesEqual $currentKeys $expected)){
        if($prior.Count -and $prior[0].Status -eq 'AddingTemporaryDeny' -and (Test-WsmShareQuiescenceAcesEqual $currentKeys $baseline.AclKeys)){$temporary=[bool]$prior[0].TemporaryDenyAdded;$expected=@($baseline.AclKeys)}
        else{throw 'Share ACL drift from the durable reviewed baseline; no ACL changes made.'}
    }
    if(-not $prior.Count){$priorRecord=[pscustomobject]@{ItemId=$Item.ItemId;BaselinePath=[IO.Path]::GetFullPath($BaselinePath);BaselineHash=$BaselineHash.ToLowerInvariant();TemporaryDenyAdded=(!$baseline.OriginalWorldDeny);Status='Prepared';Owner=$scope.Owner;Evidence=$scope.Evidence;Policy=$scope.Policy;OpenFiles=@();Sessions=@();CloseIntents=@();ClosedFileIds=@();ObservedGoneFileIds=@();UpdatedUtc=(Get-WsmUtc)};$attempt.ShareQuiescence=@($attempt.ShareQuiescence)+@($priorRecord);$saved=Save-WsmShareQuiescenceAttempt $attempt $AttemptPath;$attempt=$saved.Attempt;$prior=@($priorRecord);$temporary=[bool]$priorRecord.TemporaryDenyAdded}
    elseif($prior[0].BaselineHash -ine $BaselineHash -or $prior[0].BaselinePath -cne [IO.Path]::GetFullPath($BaselinePath)){throw 'Retry baseline differs from the first durable attempt; preserve and reconcile.'}
    if(-not $baseline.OriginalWorldDeny -and -not (Test-WsmShareQuiescenceAcesEqual $currentKeys (Get-WsmShareQuiescenceExpectedKeys $baseline $true))){
        $prior[0].TemporaryDenyAdded=$true;$prior[0].Status='AddingTemporaryDeny';$prior[0].UpdatedUtc=Get-WsmUtc;$attempt.ShareQuiescence=@($attempt.ShareQuiescence | Where-Object ItemId -CNE $Item.ItemId)+$prior;$saved=Save-WsmShareQuiescenceAttempt $attempt $AttemptPath;$attempt=$saved.Attempt
        $args=@{Name=$baseline.ShareName;AccountName=(Get-WsmEveryoneName);Force=$true;ErrorAction='Stop'};if($baseline.ScopeName){$args.ScopeName=$baseline.ScopeName};Block-SmbShareAccess @args | Out-Null
        $current=Get-WsmShareQuiescenceAces $baseline.ShareName $baseline.ScopeName;$currentKeys=Get-WsmShareQuiescenceAceKeys $current;if(-not (Test-WsmShareQuiescenceAcesEqual $currentKeys (Get-WsmShareQuiescenceExpectedKeys $baseline $true))){throw 'Temporary Everyone deny did not produce the exact expected share ACL.'}
    } else {if(-not $baseline.OriginalWorldDeny){$temporary=$true}}
    $drain=Get-WsmShareQuiescenceOpenFiles $baseline.SharePath $baseline.ShareName $baseline.ScopeName;$closed=@($prior[0].ClosedFileIds);$observedGone=@($prior[0].ObservedGoneFileIds);if(-not $prior[0].PSObject.Properties['CloseIntents']){$prior[0] | Add-Member NoteProperty CloseIntents @() -Force}
    foreach($intent in @($prior[0].CloseIntents | Where-Object {$_.Status -in @('CloseIntent','CloseFailedStillOpen')})){
        if(@($drain.Files | Where-Object {Test-WsmShareQuiescenceFileIdentity $_ $intent}).Count -eq 0){$intent.Status='ObservedGoneOnRetry';$intent | Add-Member NoteProperty ObservedUtc (Get-WsmUtc) -Force;if($observedGone -notcontains [UInt64]$intent.FileId){$observedGone+=@([UInt64]$intent.FileId)}}
    }
    $observedSessions=@($drain.Sessions)
    if($drain.Files.Count -and $scope.Policy -eq 'CloseReviewedHandles'){
        foreach($file in $drain.Files){
            # Revalidate each file id immediately before closing it; the global
            # deny has already blocked new opens, and unrelated handles/sessions
            # remain outside this operation.
            $current=Get-WsmShareQuiescenceOpenFiles $baseline.SharePath $baseline.ShareName $baseline.ScopeName
            $match=@($current.Files | Where-Object {Test-WsmShareQuiescenceFileIdentity $_ $file})
            if($match.Count -eq 1){
                if($match[0].OwnershipAmbiguous){continue}
                $intent=@($prior[0].CloseIntents | Where-Object {Test-WsmShareQuiescenceFileIdentity $_ $file} | Select-Object -First 1)
                if(-not $intent.Count){$intentRecord=[pscustomobject]@{FileId=[UInt64]$file.FileId;SessionId=[UInt64]$file.SessionId;ScopeName=[string]$file.ScopeName;Path=$file.Path;ShareRelativePath=$file.ShareRelativePath;Status='CloseIntent';IntentUtc=Get-WsmUtc};$prior[0].CloseIntents=@($prior[0].CloseIntents)+@($intentRecord)}else{$intentRecord=$intent[0];$intentRecord.Status='CloseIntent';$intentRecord.IntentUtc=Get-WsmUtc}
                $prior[0].Status='ClosingReviewedHandles';$prior[0].OpenFiles=@($current.Files);$prior[0].Sessions=@($current.Sessions);$prior[0].ClosedFileIds=@($closed);$prior[0].ObservedGoneFileIds=@($observedGone);$prior[0].UpdatedUtc=Get-WsmUtc;$attempt.ShareQuiescence=@($attempt.ShareQuiescence | Where-Object ItemId -CNE $Item.ItemId)+$prior;$saved=Save-WsmShareQuiescenceAttempt $attempt $AttemptPath;$attempt=$saved.Attempt
                try{$args=@{FileId=$file.FileId;ScopeName=$file.ScopeName;Force=$true;Confirm=$false;ErrorAction='Stop'};Close-SmbOpenFile @args | Out-Null;$intentRecord.Status='CloseCommandSucceeded';$intentRecord | Add-Member NoteProperty CompletedUtc (Get-WsmUtc) -Force;if($closed -notcontains [UInt64]$file.FileId){$closed+=@([UInt64]$file.FileId)}}catch{
                    $closeError=$_.Exception.Message;$intentRecord.Status='CloseFailed';$intentRecord | Add-Member NoteProperty Error $closeError -Force
                    try{$afterFailure=Get-WsmShareQuiescenceOpenFiles $baseline.SharePath $baseline.ShareName $baseline.ScopeName;$stillOpen=@($afterFailure.Files | Where-Object {Test-WsmShareQuiescenceFileIdentity $_ $file});if(-not $stillOpen.Count){$intentRecord.Status='CloseFailedObservedGone';$intentRecord | Add-Member NoteProperty ObservedUtc (Get-WsmUtc) -Force;if($observedGone -notcontains [UInt64]$file.FileId){$observedGone+=@([UInt64]$file.FileId)}}else{$intentRecord.Status='CloseFailedStillOpen'}}catch{$intentRecord | Add-Member NoteProperty RecheckError $_.Exception.Message -Force}
                    $prior[0].OpenFiles=@($drain.Files);$prior[0].ClosedFileIds=@($closed);$prior[0].ObservedGoneFileIds=@($observedGone);$prior[0].UpdatedUtc=Get-WsmUtc;$attempt.ShareQuiescence=@($attempt.ShareQuiescence | Where-Object ItemId -CNE $Item.ItemId)+$prior;$saved=Save-WsmShareQuiescenceAttempt $attempt $AttemptPath;throw ('Reviewed close command failed for in-scope file '+$file.FileId+'; durable intent retained, attempt hash '+$saved.AttemptHash+'. '+$closeError)
                }
                $prior[0].ClosedFileIds=@($closed);$prior[0].UpdatedUtc=Get-WsmUtc;$attempt.ShareQuiescence=@($attempt.ShareQuiescence | Where-Object ItemId -CNE $Item.ItemId)+$prior;$saved=Save-WsmShareQuiescenceAttempt $attempt $AttemptPath;$attempt=$saved.Attempt
            }elseif($match.Count -gt 1){throw 'Open-file identity became ambiguous during reviewed drain.'}else{$intentRecord=[pscustomobject]@{FileId=[UInt64]$file.FileId;SessionId=[UInt64]$file.SessionId;ScopeName=[string]$file.ScopeName;Path=$file.Path;ShareRelativePath=$file.ShareRelativePath;Status='ObservedGoneBeforeClose';ObservedUtc=Get-WsmUtc};$prior[0].CloseIntents=@($prior[0].CloseIntents)+@($intentRecord);if($observedGone -notcontains [UInt64]$file.FileId){$observedGone+=@([UInt64]$file.FileId)}}
        }
        $drain=Get-WsmShareQuiescenceOpenFiles $baseline.SharePath $baseline.ShareName $baseline.ScopeName
    }
    $prior[0].OpenFiles=@($drain.Files);$prior[0].Sessions=$observedSessions;$prior[0].ClosedFileIds=@($closed);$prior[0].ObservedGoneFileIds=@($observedGone);$prior[0].Policy=$scope.Policy;$prior[0].Evidence=$scope.Evidence
    if($drain.Files.Count){$prior[0].Status='BlockedByOpenHandles';$prior[0].UpdatedUtc=Get-WsmUtc;$attempt.ShareQuiescence=@($attempt.ShareQuiescence | Where-Object ItemId -CNE $Item.ItemId)+$prior;$saved=Save-WsmShareQuiescenceAttempt $attempt $AttemptPath;$ambiguousCount=@($drain.Files | Where-Object OwnershipAmbiguous).Count;$instruction='Resolve the reviewed in-scope handles before retrying.';if($ambiguousCount){$instruction='Same-root alias ownership is ambiguous; keep the deny in place and wait for the share owner to drain those handles naturally.'};throw ('Share deny blocks new opens, but '+$drain.Files.Count+' existing in-scope handle(s) remain. '+$instruction+' Source attempt updated; use its current hash '+$saved.AttemptHash+'.')}
    $finalAces=Get-WsmShareQuiescenceAceKeys (Get-WsmShareQuiescenceAces $baseline.ShareName $baseline.ScopeName);if(-not (Test-WsmShareQuiescenceAcesEqual $finalAces (Get-WsmShareQuiescenceExpectedKeys $baseline $temporary))){throw 'Share ACL drifted during drain; keep the deny and reconcile.'}
    $prior[0].Status='Quiesced';$prior[0].UpdatedUtc=Get-WsmUtc;$attempt.ShareQuiescence=@($attempt.ShareQuiescence | Where-Object ItemId -CNE $Item.ItemId)+$prior;$saved=Save-WsmShareQuiescenceAttempt $attempt $AttemptPath
    $activity=[pscustomobject]@{ItemId=$Item.ItemId;Kind='Share';Name=$baseline.ShareName;Path=$baseline.SharePath;State='Quiesced';BaselinePath=[IO.Path]::GetFullPath($BaselinePath);BaselineHash=$BaselineHash.ToLowerInvariant();TemporaryDenyAdded=$temporary;ClosedFileIds=@($closed);Sessions=$observedSessions;Evidence=$scope.Evidence}
    [pscustomobject]@{PairId=$Plan.PairId;ItemId=$Item.ItemId;ShareName=$baseline.ShareName;SharePath=$baseline.SharePath;Status='Quiesced';NewOpensBlocked=$true;ExistingHandles=0;ClosedFileIds=@($closed);Sessions=@($observedSessions);TemporaryDenyAdded=$temporary;Activity=$activity;AttemptPath=$saved.AttemptPath;AttemptHash=$saved.AttemptHash;ProductionVerified=$false}
}
function Restore-WsmShareQuiescence {
    [CmdletBinding()]param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)]$Item,[Parameter(Mandatory)][string]$BaselinePath,[Parameter(Mandatory)][string]$BaselineHash,[Parameter(Mandatory)][string]$AttemptPath,[Parameter(Mandatory)][string]$AttemptHash,[Parameter(Mandatory)][string]$Owner,[Parameter(Mandatory)][string]$OwnershipEvidence,[Parameter(Mandatory)][string]$Acknowledgement)
    if($Acknowledgement -cne ('SOURCE-OWNERSHIP-RESTORED '+$Plan.PairId) -or -not $Owner -or -not $OwnershipEvidence){throw 'Source share resume requires sole-writer ownership, target stop/reconciliation evidence and exact pair acknowledgement.'}
    $scope=Get-WsmShareQuiescenceScope $Plan $Item;Assert-WsmMigrationHost (Get-WsmMachineIdentity) $Plan.Source.Fingerprint;$saved=Get-WsmShareQuiescenceAttempt $Plan $Item $BaselinePath $BaselineHash $AttemptPath $AttemptHash;$attempt=$saved.Attempt;$baseline=$saved.Baseline;$share=Assert-WsmShareQuiescenceLiveIdentity $baseline
    $record=@($saved.Record);if($record.Count -ne 1 -or $record[0].Status -notin @('Prepared','AddingTemporaryDeny','ClosingReviewedHandles','Quiesced','BlockedByOpenHandles','SourceResumed')){throw 'Source share has no durable quiescence attempt to resume.'};$temporary=[bool]$record[0].TemporaryDenyAdded
    $current=Get-WsmShareQuiescenceAces $baseline.ShareName $baseline.ScopeName;$currentKeys=Get-WsmShareQuiescenceAceKeys $current
    $aclIsOriginal=Test-WsmShareQuiescenceAcesEqual $currentKeys $baseline.AclKeys
    $aclIsQuiesced=Test-WsmShareQuiescenceAcesEqual $currentKeys (Get-WsmShareQuiescenceExpectedKeys $baseline $temporary)
    if(-not $aclIsQuiesced -and -not ($temporary -and $aclIsOriginal)){throw 'Share ACL drifted after quiescence; source permissions will not be rewritten.'}
    $drain=Get-WsmShareQuiescenceOpenFiles $baseline.SharePath $baseline.ShareName $baseline.ScopeName;if($drain.Files.Count){throw 'Source share still has open files; resolve target ownership and close in-scope handles before resuming source.'}
    if($record[0].Status -eq 'SourceResumed' -and $aclIsOriginal){[pscustomobject]@{PairId=$Plan.PairId;ItemId=$Item.ItemId;ShareName=$baseline.ShareName;Status='SourceResumed';ExactBaselineRestored=$true;TemporaryDenyRemoved=$temporary;AttemptPath=[IO.Path]::GetFullPath($AttemptPath);AttemptHash=$AttemptHash;ProductionVerified=$false};return}
    $expected=@{};foreach($key in $baseline.AclKeys){$expected[$key]=$true}
    foreach($ace in $current){$sid=$ace.AccountSid;$key=$sid+'|'+$ace.AccessControlType+'|'+$ace.AccessRight;if(-not $expected.ContainsKey($key)){
            if(-not ($temporary -and $sid -eq 'S-1-1-0' -and $ace.AccessControlType -eq 'Deny' -and $ace.AccessRight -eq 'Full')){throw 'Unexpected share ACE cannot be attributed to this tool; preserve it.'}
            $args=@{Name=$baseline.ShareName;AccountName=$ace.AccountName;Force=$true;ErrorAction='Stop'};if($baseline.ScopeName){$args.ScopeName=$baseline.ScopeName};Unblock-SmbShareAccess @args | Out-Null
        }}
    $current=Get-WsmShareQuiescenceAces $baseline.ShareName $baseline.ScopeName;$currentKeys=Get-WsmShareQuiescenceAceKeys $current
    foreach($ace in $baseline.Access){$key=$ace.AccountSid+'|'+$ace.AccessControlType+'|'+$ace.AccessRight;if($currentKeys -notcontains $key){$args=@{Name=$baseline.ShareName;AccountName=$ace.AccountName;Force=$true;ErrorAction='Stop'};if($baseline.ScopeName){$args.ScopeName=$baseline.ScopeName};if($ace.AccessControlType -eq 'Allow'){$args.AccessRight=$ace.AccessRight;Grant-SmbShareAccess @args | Out-Null}else{Block-SmbShareAccess @args | Out-Null}}}
    $restored=Get-WsmShareQuiescenceAceKeys (Get-WsmShareQuiescenceAces $baseline.ShareName $baseline.ScopeName);if(-not (Test-WsmShareQuiescenceAcesEqual $restored $baseline.AclKeys)){throw 'Restored share ACL differs from the exact saved baseline.'}
    $record[0].Status='SourceResumed';$record[0] | Add-Member NoteProperty ResumeOwner $Owner -Force;$record[0] | Add-Member NoteProperty OwnershipEvidence $OwnershipEvidence -Force;$record[0].UpdatedUtc=Get-WsmUtc;$attempt.ShareQuiescence=@($attempt.ShareQuiescence | Where-Object ItemId -CNE $Item.ItemId)+$record;$saved=Save-WsmShareQuiescenceAttempt $attempt $AttemptPath
    [pscustomobject]@{PairId=$Plan.PairId;ItemId=$Item.ItemId;ShareName=$baseline.ShareName;Status='SourceResumed';ExactBaselineRestored=$true;TemporaryDenyRemoved=$temporary;AttemptPath=$saved.AttemptPath;AttemptHash=$saved.AttemptHash;ProductionVerified=$false}
}
