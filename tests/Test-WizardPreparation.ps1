#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '../src/WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path $env:TEMP ('wsm-wprep-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root,$Helper)
        # Exercise the helper exported by the production module, without local shadows.
        $checks=0
        function Check([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:wizardPreparationCheckCount++}
        function Reject([scriptblock]$action,[string]$message){$failed=$false;try{& $action|Out-Null}catch{$failed=$true};Check $failed $message}
        $script:wizardPreparationCheckCount=0
        $work=Join-Path $Root 'manager';Initialize-WsmWizardWorkspace $work Manager|Out-Null
        $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString('D');Fingerprint=('a'*64);Name='Form fixture source'}
        $item=New-WsmItem $source.HostId Storage PathCandidate 'Business files' 'C:\business-data' ([pscustomobject][ordered]@{OriginalPath='C:\business-data';ResolvedCandidate='C:\business-data'})
        $inventory=New-WsmInventory $source 1 @($item);$inventoryPath=Join-Path $Root 'inventory.json';Write-WsmJson $inventoryPath $inventory
        $catalog=Import-WsmInventory $work $inventoryPath (Get-FileHash -LiteralPath $inventoryPath).Hash 'Form fixture target'
        $catalog=Enable-WsmAssistiveMode $work $catalog.PairId $catalog.DecisionRevision
        $form=Get-WsmWizardPreparationReview $work $catalog.PairId $item.ItemId
        Check ($form.Kind -ceq 'WizardPreparationReview' -and $form.ReviewHash -match '^[a-f0-9]{64}$') 'The form does not carry a current typed core review binding.'
        $target=@($form.FormFields|Where-Object key -CEQ 'TargetPath')[0];$channel=@($form.FormFields|Where-Object key -CEQ 'TransferChannel')[0]
        Check ($target.value -ceq 'C:\business-data' -and $target.editable -and $target.label -notmatch '^TargetPath$') 'The safe source-derived destination draft was not prefilled in plain language.'
        Check (-not $channel.editable -and $channel.value -ceq 'C' -and -not @($form.FormFields|Where-Object key -CEQ 'SourcePath').Count) 'The form permits changing the source scope or transfer channel.'
        Check (-not $form.RawXmlIncluded -and -not $form.SecretsIncluded -and -not $form.AuthoritativeApproval) 'A draft form falsely reports approval or leaks raw definitions.'
        Reject {Save-WsmWizardPreparationReview $work $catalog.PairId $item.ItemId $form.ReviewHash 'Owner' 'Reviewed business data' @{TransferChannel='NonC'}} 'A browser answer changed a source-derived channel.'
        Reject {Save-WsmWizardPreparationReview $work $catalog.PairId $item.ItemId $form.ReviewHash 'Owner' 'Reviewed business data' @{Unexpected='arbitrary spec field'}} 'An unknown answer injected a specification field.'
        Reject {Save-WsmWizardPreparationReview $work $catalog.PairId $item.ItemId $form.ReviewHash 'Owner' 'Reviewed business data' @{AclControlPolicy='AllowEverything'}} 'An unsafe ACL option bypassed the core review policy.'
        Reject {Save-WsmWizardPreparationReview $work $catalog.PairId $item.ItemId ('b'*64) 'Owner' 'Reviewed business data' @{}} 'An unrelated form hash was accepted.'
        $beforeInvalid=Get-WsmCatalog $work $catalog.PairId
        $invalidError=$null;try{Save-WsmWizardPreparationReview $work $catalog.PairId $item.ItemId $form.ReviewHash 'Owner' 'Typed field error fixture' @{Consistency='not-an-allowed-option-secret-sentinel'}|Out-Null}catch{$invalidError=Get-WsmHtmlSafeError $_.Exception.Message $_.Exception.GetType().FullName}
        Check ($invalidError -and $invalidError.code -ceq 'field_validation' -and $invalidError.fieldErrors[0].pointer -ceq '/Answers/Consistency' -and $invalidError.fieldErrors[0].reason -ceq 'option') 'The real invalid form answer did not reach the structured field-error consumer.'
        Check (($invalidError|ConvertTo-Json -Depth 10) -notmatch 'secret-sentinel') 'Field-error projection reflected entered values.'
        Check ((Get-WsmCatalog $work $catalog.PairId).DecisionRevision -eq $beforeInvalid.DecisionRevision) 'Invalid typed answer changed the authoritative catalog.'
        $saved=Save-WsmWizardPreparationReview $work $catalog.PairId $item.ItemId $form.ReviewHash 'Fixture business owner' 'Reviewed this folder as business data; no installation binaries' @{ContentSelection='WholeScope';Consistency='Immutable';BusinessChecks="Read file one`nRead file two"}
        $current=Get-WsmCatalog $work $catalog.PairId;$spec=@($current.Items|Where-Object ItemId -CEQ $item.ItemId)[0].MigrationSpec
        Check ($spec.ContentSelection -ceq 'WholeScope' -and $spec.Consistency -ceq 'Immutable' -and $spec.BusinessChecks.Count -eq 2 -and $spec.Owner -ceq 'Fixture business owner') 'The plain form did not reach the real specification consumer with exact answers.'
        Check ($saved.SpecHash -match '^[a-f0-9]{64}$' -and [IO.File]::Exists($saved.SpecPath) -and -not $current.Approval) 'Saving the form did not produce an actual spec artifact, or approved the plan implicitly.'
        Reject {Save-WsmWizardPreparationReview $work $catalog.PairId $item.ItemId $form.ReviewHash 'Owner' 'Old answer' @{}} 'A stale form was silently rebound to newer core revisions.'
        $reopened=Get-WsmWizardPreparationReview $work $catalog.PairId $item.ItemId
        Check ($reopened.Owner -ceq 'Fixture business owner' -and $reopened.ReviewHash -cne $form.ReviewHash) 'Current human review values did not survive reopen.'
        $nested=Get-WsmWizardPreparationForm ([ordered]@{BusinessChecks=@();IisBindings=@([pscustomobject]@{Index=0;Protocol='http';BindingInformation='*:8080:example.invalid';SslFlagsPresent=$false});WorkloadFieldReviews=@([pscustomobject]@{FieldPointer='Task/Actions/Action[0]/Command';Value='C:\new\task.exe'})})
        Check (@($nested|Where-Object {$_.key -ceq 'BusinessChecks' -and $_.type -ceq 'lines'}).Count -eq 1) 'An empty string list lost its editable list type.'
        Check (@($nested|Where-Object {$_.key -ceq 'IisBindings/0/Index' -and -not $_.editable}).Count -eq 1 -and @($nested|Where-Object {$_.key -ceq 'WorkloadFieldReviews/0/Value' -and $_.editable}).Count -eq 1) 'Nested fields require JSON or permit changing their exact row identity.'
        $activation=Get-WsmWizardPreparationFields ([pscustomobject]@{Adapter='ScheduledTask';TypedFields=[pscustomobject]@{ActivationOwner='Already reviewed owner';ActivationReason='Already reviewed reason';DesiredFinalState='Disabled'};SharedResourceReviewReasons=@()})
        Check ($activation.ActivationOwner -ceq 'Already reviewed owner' -and $activation.ActivationReason -ceq 'Already reviewed reason') 'Existing safe human activation evidence was replaced with blank questions.'
        $activationMissing=Get-WsmWizardPreparationFields ([pscustomobject]@{Adapter='IISSection';TypedFields=[pscustomobject]@{};SharedResourceReviewReasons=@()})
        Check ($activationMissing.Contains('ActivationOwner') -and $activationMissing.ActivationOwner -ceq '' -and $activationMissing.ActivationReason -ceq '') 'Missing activation responsibility was fabricated or inaccessible.'
        $singleOption=@($form.FormFields|Where-Object key -CEQ 'ConflictPolicy')[0];Check ($singleOption.options -is [array] -and $singleOption.options.Count -eq 1) 'A single choice option became a scalar and broke the browser select.'
        $extended=Get-WsmWizardPreparationFields ([pscustomobject]@{Adapter='IISSection';TypedFields=[pscustomobject]@{PrincipalUser='DOMAIN\reviewed-user';ConfigOverrides=@();IisConfigChanges=@([pscustomobject]@{FieldPointer='configuration/system.webServer/@enabled';AfterValue='true';BeforeValue='[withheld]'});DesiredChanges=@();ActivationPolicyFieldPointer='configuration/system.webServer/@enabled'};SharedResourceReviewReasons=@()})
        Check ($extended.Contains('PrincipalUser') -and $extended.Contains('ConfigOverrides') -and $extended.Contains('IisConfigChanges') -and $extended.Contains('DesiredChanges') -and $extended.Contains('ActivationPolicyFieldPointer')) 'The plain review omitted typed fields supported by the core review consumer.'
        $extendedForm=@(Get-WsmWizardPreparationForm $extended)
        Check (@($extendedForm|Where-Object {$_.key -ceq 'IisConfigChanges/0/FieldPointer' -and -not $_.editable}).Count -eq 1 -and @($extendedForm|Where-Object {$_.key -ceq 'ActivationPolicyFieldPointer' -and -not $_.editable}).Count -eq 1) 'The plain form permits replacing exact configuration/activation row identities.'
        Check (@($extendedForm|Where-Object {$_.key -ceq 'IisConfigChanges/0/BeforeValue' -and -not $_.editable}).Count -eq 1 -and @($extendedForm|Where-Object {$_.key -ceq 'IisConfigChanges/0/AfterValue' -and $_.editable -and $_.label -cne 'AfterValue'}).Count -eq 1) 'Withheld source values became editable or a safe reviewed change was inaccessible.'
        $blankIis=@(Get-WsmWizardPreparationForm ([ordered]@{IisConfigChanges=@([pscustomobject]@{FieldPointer='configuration/system.webServer/@enabled';BeforeValue='[withheld]';AfterValue=''})}))
        Check (@($blankIis|Where-Object {$_.key -ceq 'IisConfigChanges/0/AfterValue' -and $_.value -ceq '' -and $_.origin -ceq 'NeedsHumanDecision'}).Count -eq 1) 'A blank IIS target choice was not presented as a human decision.'
        $desiredReview=Get-WsmWizardPreparationFields ([pscustomobject]@{Adapter='LocalUser';TypedFields=[pscustomobject]@{Desired=[pscustomobject][ordered]@{Name='fixture-user';FullName='';Description='';Password='do-not-leak'};SecretRef=''};SharedResourceReviewReasons=@()})
        $desiredForm=@(Get-WsmWizardPreparationForm $desiredReview 'LocalUser')
        Check (@($desiredForm|Where-Object {$_.key -ceq 'Desired/Name' -and -not $_.editable}).Count -eq 1 -and @($desiredForm|Where-Object {$_.key -ceq 'Desired/FullName' -and $_.editable -and $_.label -ceq '帳號顯示名稱'}).Count -eq 1) 'The safe local-user form omitted editable display metadata or allowed changing the protected account identity.'
        Check (@($desiredForm|Where-Object {$_.key -ceq 'SecretRef' -and $_.editable -and $_.required -and $_.value -ceq '' -and $_.label -match '參照名稱'}).Count -eq 1 -and -not @($desiredForm|Where-Object {$_.key -match '(?i)password|credential|privatekey'}).Count) 'The form did not request a blank reference-only SecretRef or exposed secret-bearing fields.'
        $smbReview=Get-WsmWizardPreparationFields ([pscustomobject]@{Adapter='SmbShare';TypedFields=[pscustomobject]@{Desired=[pscustomobject][ordered]@{Name='fixture-share';Path='C:\data';Description='';EncryptData=$false;DrainPolicy='BlockNewOpens';DrainEvidence='';Access=@([pscustomobject]@{AccountName='FIXTURE\Reader';AccessControlType='Allow';AccessRight='Read'})}};SharedResourceReviewReasons=@()})
        $smbForm=@(Get-WsmWizardPreparationForm $smbReview 'SmbShare')
        Check (@($smbForm|Where-Object {$_.key -ceq 'Desired/EncryptData' -and $_.editable -and $_.type -ceq 'boolean' -and $_.label -ceq '啟用 SMB 傳輸加密'}).Count -eq 1 -and @($smbForm|Where-Object {$_.key -ceq 'Desired/Access/0/AccountName' -and $_.editable -and $_.label -ceq '權限帳號'}).Count -eq 1) 'The SMB form did not render bounded human-readable configuration decisions.'
        $taskBlankFields=[ordered]@{WorkloadFieldReviews=@([pscustomobject]@{FieldPointer='Task/Actions/Action[0]/Arguments';Value=''},[pscustomobject]@{FieldPointer='Task/Actions/Action[0]/Command';Value=''})}
        $taskBlankForm=@(Get-WsmWizardPreparationForm $taskBlankFields 'ScheduledTask')
        Check (-not @($taskBlankForm|Where-Object key -CEQ 'WorkloadFieldReviews/0/Value')[0].required -and @($taskBlankForm|Where-Object key -CEQ 'WorkloadFieldReviews/1/Value')[0].required) 'A legitimate empty task argument required invented text, or an empty executable command was allowed.'
        $passwordForm=@(Get-WsmWizardPreparationForm ([ordered]@{SecretRef=''}) 'Service' 'UserPassword')
        $builtinForm=@(Get-WsmWizardPreparationForm ([ordered]@{SecretRef=''}) 'Service' 'LocalSystem')
        Check ($passwordForm[0].required -and -not $builtinForm[0].required) 'Service SecretRef requiredness depended on an unrelated dynamically scoped review instead of explicit account mode.'
        Write-Output ('PASS: '+$script:wizardPreparationCheckCount+' plain form/core specification, bounds, source identity and stale review checks.')
    } $root (Join-Path $PSScriptRoot '../src/WizardPreparation.ps1')
} finally {
    $absolute=[IO.Path]::GetFullPath($root);$prefix=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if(-not $absolute.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Test cleanup escaped the owned temporary root.'}
    Remove-Item -LiteralPath $absolute -Recurse -Force
}
