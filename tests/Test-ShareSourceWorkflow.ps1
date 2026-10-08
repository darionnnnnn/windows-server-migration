#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path 'C:\' ('wsm-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
& $module {
    param($Root)
    $script:workflowRoot=$Root;$script:fixtureSource=$null;$script:fixtureFingerprint=('a'*64);$script:inventoryRevision=0
    $script:share=[pscustomobject]@{Name='Data';Path='C:\Fixture\data';ScopeName='';Description='Fixture share';EncryptData=$false;Special=$false};$script:shares=@($script:share,[pscustomobject]@{Name='C$';Path='C:\';ScopeName=''},[pscustomobject]@{Name='IPC$';Path='';ScopeName=''})
    $script:worldName='Fixture Local Everyone';$script:acl=@();$script:openFiles=@();$script:sessions=@();$script:closeCalls=@();$script:closeAfterEffectFileId=[UInt64]0;$script:blockCalls=0;$script:unblockCalls=0
    function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:fixtureFingerprint;Name='fixture-source';OS='Fixture Windows Server';Version='10.fixture';IsServer=$true;Administrator=$true;Is64Bit=$true}}
    # Keep the approval fingerprint stable during this fixture while other agents edit project files.
    function script:Get-WsmToolFingerprint {('d'*64)}
    function script:Get-WsmEveryoneName {$script:worldName}
    function script:Resolve-WsmAccountSid([string]$Account){switch -CaseSensitive ($Account){'Fixture Local Everyone'{'S-1-1-0'};'S-1-1-0'{'S-1-1-0'};'Fixture Readers'{'S-1-5-21-777-888-999-1001'};'Fixture Writers'{'S-1-5-21-777-888-999-1002'};default{throw ('Unknown workflow fixture account: '+$Account)}}}
    function script:Get-SmbShare {param($Name,$ScopeName,$ErrorAction)if($PSBoundParameters.ContainsKey('Name')){if($Name -ceq $script:share.Name){return $script:share};return @()};@($script:shares)}
    function script:Get-SmbShareAccess {param($Name,$ScopeName,$ErrorAction)if($Name -cne $script:share.Name){throw 'Unexpected share ACL query'};@($script:acl)}
    function script:Block-SmbShareAccess {param($Name,$ScopeName,$AccountName,[switch]$Force,$ErrorAction)if($Name -cne $script:share.Name){throw 'Unexpected share deny target'};$script:blockCalls++;if(-not @($script:acl | Where-Object {$_.AccountName -ceq $AccountName -and $_.AccessControlType -eq 'Deny'}).Count){$script:acl+=@([pscustomobject]@{AccountName=$AccountName;AccessControlType='Deny';AccessRight='Full'})}}
    function script:Unblock-SmbShareAccess {param($Name,$ScopeName,$AccountName,[switch]$Force,$ErrorAction)if($Name -cne $script:share.Name){throw 'Unexpected share deny removal'};$script:unblockCalls++;$script:acl=@($script:acl | Where-Object {-not ($_.AccountName -ceq $AccountName -and $_.AccessControlType -eq 'Deny')})}
    function script:Grant-SmbShareAccess {param($Name,$ScopeName,$AccountName,$AccessRight,[switch]$Force,$ErrorAction)$script:acl+=@([pscustomobject]@{AccountName=$AccountName;AccessControlType='Allow';AccessRight=$AccessRight})}
    function script:Get-SmbOpenFile {param([string[]]$ScopeName,$ErrorAction)if($ScopeName -cne '*'){throw 'Open-file query omitted or widened the exact SMB scope'};@($script:openFiles)}
    function script:Get-SmbSession {param([string[]]$ScopeName,$ErrorAction)if($ScopeName -cne '*'){throw 'Session query omitted or widened the exact SMB scope'};@($script:sessions)}
    function script:Close-SmbOpenFile {param([UInt64]$FileId,[string[]]$ScopeName,[switch]$Force,[bool]$Confirm,$ErrorAction)if($ScopeName -cne '*'){throw 'Close omitted or widened the exact SMB scope'};$script:closeCalls+=@($FileId);$script:openFiles=@($script:openFiles | Where-Object {[UInt64]$_.FileId -ne $FileId});if($FileId -eq $script:closeAfterEffectFileId){$script:closeAfterEffectFileId=0;throw 'fixture Close-SmbOpenFile transport failed after the file was closed'}}
    function script:Export-WsmInventory {
        param([Parameter(Mandatory)][string]$OutputDirectory,[switch]$DeepDiscovery)
        $script:inventoryRevision++
        $access=@(Get-SmbShareAccess -Name $script:share.Name -ErrorAction Stop | Select-Object AccountName,AccessControlType,AccessRight)
        $settings=[ordered]@{Definition=[ordered]@{Name=$script:share.Name;Path=$script:share.Path;ScopeName=$script:share.ScopeName;Description=$script:share.Description;EncryptData=[bool]$script:share.EncryptData;Special=[bool]$script:share.Special};Access=$access}
        $item=New-WsmItem $script:fixtureSource.HostId Storage Share $script:share.Name $script:share.Name $settings @() Success SmbShare
        $inventory=New-WsmInventory $script:fixtureSource $script:inventoryRevision @($item)
        $path=Join-Path $OutputDirectory ('fixture-inventory-'+$script:inventoryRevision+'.json');Write-WsmJson $path $inventory
        [pscustomobject]@{Path=$path;SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
    }
    function New-WorkflowCase([string]$CaseName,[bool]$OriginalWorldDeny=$false) {
        $caseRoot=Join-Path $script:workflowRoot $CaseName;$workspace=Join-Path $caseRoot 'manager';$sourceState=Join-Path $caseRoot 'source';[void][IO.Directory]::CreateDirectory($caseRoot);[void][IO.Directory]::CreateDirectory($sourceState);Initialize-WsmWorkspace $workspace | Out-Null
        $script:fixtureFingerprint=('a'*64);$script:fixtureSource=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=$script:fixtureFingerprint;Name='fixture-source';OS='Fixture Windows Server';Version='10.fixture'};$script:inventoryRevision=0;$script:share=[pscustomobject]@{Name='Data';Path='C:\Fixture\data';ScopeName='';Description='Fixture share';EncryptData=$false;Special=$false};$script:shares=@($script:share,[pscustomobject]@{Name='C$';Path='C:\';ScopeName=''},[pscustomobject]@{Name='IPC$';Path='';ScopeName=''})
        $script:acl=@([pscustomobject]@{AccountName='Fixture Readers';AccessControlType='Allow';AccessRight='Read'},[pscustomobject]@{AccountName='Fixture Writers';AccessControlType='Allow';AccessRight='Change'});if($OriginalWorldDeny){$script:acl+=@([pscustomobject]@{AccountName=$script:worldName;AccessControlType='Deny';AccessRight='Full'})}
        $script:openFiles=@();$script:sessions=@();$script:closeCalls=@();$script:closeAfterEffectFileId=0;$script:blockCalls=0;$script:unblockCalls=0
        $inventoryResult=Export-WsmInventory $sourceState;$catalog=Import-WsmInventory $workspace $inventoryResult.Path $inventoryResult.SHA256 'fixture-target';Set-WsmDecision $workspace $catalog.PairId @($catalog.Items | ForEach-Object ItemId) Include 'reviewed share migration' 0 | Out-Null
        $bundlePath=Join-Path $caseRoot 'specs.json';Export-WsmMigrationSpecBundle $workspace $catalog.PairId $bundlePath | Out-Null;$bundle=Read-WsmJson $bundlePath;$bundle.Rows[0].MigrationSpec.Owner='fixture storage owner';$bundle.Rows[0].MigrationSpec.Evidence='fixture-approved storage change record';$bundle.Rows[0].MigrationSpec.Desired.DrainPolicy='CloseReviewedHandles';$bundle.Rows[0].MigrationSpec.Desired.DrainEvidence='Reviewed fixture drain procedure';Write-WsmJson $bundlePath $bundle
        Import-WsmMigrationSpecBundle $workspace $catalog.PairId $bundlePath (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash 1 APPLY-SPECS | Out-Null
        $script:fixtureFingerprint=('b'*64);$identity=Register-WsmTarget (Join-Path $caseRoot 'target-state') (Join-Path $caseRoot 'target-identity.json')
        $approvedPath=Join-Path $caseRoot 'approved-plan.json';$revision=(Get-WsmCatalog $workspace $catalog.PairId).DecisionRevision;$approval=Approve-WsmMigrationPlan $workspace $catalog.PairId $identity.Path $identity.SHA256 $approvedPath $revision ISOLATED-PILOT;$script:fixtureFingerprint=('a'*64)
        [pscustomobject]@{Root=$caseRoot;Workspace=$workspace;SourceState=$sourceState;PairId=$catalog.PairId;ItemId=$catalog.Items[0].ItemId;PlanPath=$approvedPath;PlanHash=$approval.SHA256;FreezePath=(Join-Path $caseRoot 'freeze.json')}
    }
    function Get-FixtureAclKeys { @(Get-WsmShareQuiescenceAceKeys (Get-WsmShareQuiescenceAces 'Data')) }
    function Assert-FixtureAcl([string[]]$Expected,[string]$Context) {$actual=Get-FixtureAclKeys;if((($actual|Sort-Object)-join ';') -cne (($Expected|Sort-Object)-join ';')){throw ($Context+'; observed ACL '+($actual -join ';'))}}

    # The first freeze fails after the mock close API takes effect. The durable intent and original ACL baseline must survive for same-plan retry.
    $case=New-WorkflowCase 'partial-retry' $false
    $script:openFiles=@(
        [pscustomobject]@{FileId=[UInt64]901;ScopeName='*';SessionId=[UInt64]501;Path='C:\Fixture\data\ledger.db';ShareRelativePath='ledger.db';ClientComputerName='fixture-client';ClientUserName='Fixture Writers'},
        [pscustomobject]@{FileId=[UInt64]902;ScopeName='*';SessionId=[UInt64]502;Path='C:\Fixture\data-archive\unowned.txt';ShareRelativePath='unowned.txt';ClientComputerName='other-client';ClientUserName='Unowned Account'}
    );$script:sessions=@([pscustomobject]@{SessionId=[UInt64]501;ClientComputerName='fixture-client';ClientUserName='Fixture Writers';NumOpens=1;ScopeName='*'},[pscustomobject]@{SessionId=[UInt64]502;ClientComputerName='other-client';ClientUserName='Unowned Account';NumOpens=1;ScopeName='*'});$script:closeAfterEffectFileId=[UInt64]901
    $partialFailure=$false;$partialMessage='';try{Export-WsmFreezeRecord $case.PlanPath $case.PlanHash $case.FreezePath 'fixture storage owner' 'fixture writers coordinated' OWNER-CONFIRMED-QUIESCENCE -SourceStateDirectory $case.SourceState | Out-Null}catch{$partialFailure=$true;$partialMessage=$_.Exception.Message+' | '+$_.ScriptStackTrace}
    if(-not $partialFailure -or (Test-Path -LiteralPath $case.FreezePath) -or $partialMessage -notmatch 'Source freeze interrupted; retain baseline and retry'){$files=(@(Get-ChildItem -LiteralPath $Root -Recurse -Force | ForEach-Object FullName) -join '|');throw ('Failed close-after-effect incorrectly produced a freeze handoff or lost the retry instruction. Root='+$Root+'; Files='+$files+'; Failure='+$partialFailure+'; FreezeExists='+(Test-Path -LiteralPath $case.FreezePath)+'; Message='+$partialMessage)}
    if($script:closeCalls.Count -ne 1 -or $script:closeCalls[0] -ne 901 -or @($script:openFiles | Where-Object FileId -EQ 902).Count -ne 1){throw 'Freeze closed an out-of-scope/unowned handle or failed to record the close attempt.'}
    Assert-FixtureAcl @('S-1-5-21-777-888-999-1001|Allow|Read','S-1-5-21-777-888-999-1002|Allow|Change','S-1-1-0|Deny|Full') 'Temporary deny missing after interrupted drain'
    $attemptFiles=@(Get-ChildItem -LiteralPath $case.SourceState -Filter attempt.json -Recurse);if($attemptFiles.Count -ne 1){throw 'Interrupted SourceAttempt was not durably retained.'};$firstAttemptPath=$attemptFiles[0].FullName;$firstAttempt=Read-WsmJson $firstAttemptPath
    if($firstAttempt.Status -ne 'Interrupted' -or $firstAttempt.ShareQuiescence.Count -ne 1 -or $firstAttempt.ShareQuiescence[0].Status -ne 'ClosingReviewedHandles'){throw 'Interrupted source workflow did not retain its original attempt state.'}
    $firstShareRecord=$firstAttempt.ShareQuiescence[0];$firstCloseIntent=@($firstShareRecord.CloseIntents | Where-Object FileId -EQ 901);if($firstCloseIntent.Count -ne 1 -or $firstCloseIntent[0].Status -ne 'CloseFailedObservedGone' -or @($firstShareRecord.ObservedGoneFileIds | Where-Object {$_ -eq 901}).Count -ne 1){throw 'Close-after-effect evidence was not retained as observed-gone without claiming a successful close.'}
    $originalShareBaseline=$firstAttempt.ShareBaselines | Where-Object ItemId -EQ $case.ItemId;$baselinePath=$originalShareBaseline.Path;$baselineHash=$originalShareBaseline.SHA256;$savedBaseline=Read-WsmTrustedJson $baselinePath $baselineHash
    $baselineAces=@(Get-WsmShareQuiescenceAceKeys $savedBaseline.Access);if($savedBaseline.OriginalWorldDeny -or $baselineAces -contains 'S-1-1-0|Deny|Full'){throw 'The durable baseline captured the post-deny ACL instead of the original ACL.'}

    # Retry uses the same approved plan and first baseline. It inventories the deny state, drains the remaining in-scope work, and writes a fresh freeze record.
    $retryFreeze=Export-WsmFreezeRecord $case.PlanPath $case.PlanHash $case.FreezePath 'fixture storage owner' 'fixture retry retained original ACL baseline' OWNER-CONFIRMED-QUIESCENCE -SourceStateDirectory $case.SourceState -PreviousAttemptPath $firstAttemptPath -PreviousAttemptHash (Get-FileHash -LiteralPath $firstAttemptPath -Algorithm SHA256).Hash
    if(-not (Test-Path -LiteralPath $case.FreezePath) -or $retryFreeze.SourceAttemptPath -eq $firstAttemptPath){throw 'Retry did not create a fresh freeze result and SourceAttempt.'}
    $secondAttempt=Read-WsmTrustedJson $retryFreeze.SourceAttemptPath $retryFreeze.SourceAttemptHash;$secondBaseline=@($secondAttempt.ShareBaselines | Where-Object ItemId -EQ $case.ItemId)
    if($secondBaseline.Count -ne 1 -or $secondBaseline[0].Path -cne $baselinePath -or $secondBaseline[0].SHA256 -ine $baselineHash){throw 'Retry recaptured or replaced the original share ACL baseline.'}
    $savedFreeze=Read-WsmTrustedJson $retryFreeze.Path $retryFreeze.SHA256;$shareActivity=@($savedFreeze.Activities | Where-Object {$_.ItemId -ceq $case.ItemId -and $_.Kind -eq 'Share' -and $_.State -eq 'Quiesced'});if($shareActivity.Count -ne 1){throw 'Fresh freeze record lacks the successful share quiescence activity.'}
    if(@($script:closeCalls | Where-Object {$_ -eq 901}).Count -ne 1 -or @($script:openFiles | Where-Object FileId -EQ 902).Count -ne 1){throw 'Retry repeated a closed handle operation or touched the out-of-scope unowned handle.'}
    $resume=Invoke-WsmSourceResume $case.PlanPath $case.PlanHash $retryFreeze.SourceAttemptPath $retryFreeze.SourceAttemptHash $case.SourceState 'fixture storage owner' 'target stopped and writes reconciled' ('SOURCE-OWNERSHIP-RESTORED '+$case.PairId)
    if($resume.Status -ne 'SourceResumed'){throw 'Source resume workflow did not complete.'}
    Assert-FixtureAcl @('S-1-5-21-777-888-999-1001|Allow|Read','S-1-5-21-777-888-999-1002|Allow|Change') 'Source resume failed to restore the exact original share ACL'
    if($script:unblockCalls -ne 1 -or @($script:openFiles | Where-Object FileId -EQ 902).Count -ne 1){throw 'Resume changed the wrong share ACE or touched the unowned out-of-scope handle.'}
    $resumedAttempt=Read-WsmTrustedJson $resume.Path $resume.SHA256;if($resumedAttempt.Status -ne 'SourceResumed' -or @($resumedAttempt.ShareQuiescence | Where-Object {$_.ItemId -ceq $case.ItemId -and $_.Status -eq 'SourceResumed'}).Count -ne 1){throw 'Final SourceAttempt did not record source share ACL restoration.'}

    # A source that already has Everyone deny keeps that ACE through freeze and resume; the tool must not claim or remove it.
    $alreadyDenied=New-WorkflowCase 'existing-world-deny' $true;$originalDeniedKeys=Get-FixtureAclKeys;$unblocksBeforeDenied=$script:unblockCalls
    $deniedFreeze=Export-WsmFreezeRecord $alreadyDenied.PlanPath $alreadyDenied.PlanHash $alreadyDenied.FreezePath 'fixture storage owner' 'existing deny reviewed' OWNER-CONFIRMED-QUIESCENCE -SourceStateDirectory $alreadyDenied.SourceState
    $deniedAttempt=Read-WsmTrustedJson $deniedFreeze.SourceAttemptPath $deniedFreeze.SourceAttemptHash;$deniedRecord=@($deniedAttempt.ShareQuiescence | Where-Object ItemId -EQ $alreadyDenied.ItemId)[0]
    if($deniedRecord.TemporaryDenyAdded -or $script:blockCalls -ne 0){throw 'Existing Everyone deny was recorded as tool-owned or redundantly recreated.'}
    Invoke-WsmSourceResume $alreadyDenied.PlanPath $alreadyDenied.PlanHash $deniedFreeze.SourceAttemptPath $deniedFreeze.SourceAttemptHash $alreadyDenied.SourceState 'fixture storage owner' 'target stopped and writes reconciled' ('SOURCE-OWNERSHIP-RESTORED '+$alreadyDenied.PairId) | Out-Null
    Assert-FixtureAcl $originalDeniedKeys 'Source resume removed a pre-existing Everyone deny'
    if($script:unblockCalls -ne $unblocksBeforeDenied){throw 'Source resume removed an Everyone deny it did not add.'}
    Write-Host ('PASS: real Export-WsmFreezeRecord/Invoke-WsmFreezeCore and Invoke-WsmSourceResume workflows with a fake share OS boundary; durable interrupted close-after-effect intent, same-plan fresh-freeze retry, original ACL baseline retention, exact ACL restoration, pre-existing Everyone deny preservation, and untouched out-of-scope/unowned handle. All SMB APIs are fixtures; durable JSON/hash/lock workflows used real owned temporary files. Fixture root: '+$Root)
} $root
$resolvedRoot=[IO.Path]::GetFullPath($root)
if($resolvedRoot -notmatch '^C:\\wsm-[a-f0-9]{32}$'){throw 'Refusing cleanup outside this test-owned root.'}
Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
