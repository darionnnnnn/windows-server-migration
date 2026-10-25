#requires -Version 5.1
# S8/S9/S10: the preparation form and the bulk preview must judge empty values, option fields
# and read-only IIS identity fields with the same rules.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
try {
    & $module {
        $script:checks=0
        function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
        function Row($Rows,[string]$Key){$found=@($Rows|Where-Object {$_.key -ceq $Key});if($found.Count -ne 1){throw ('Expected exactly one form row for '+$Key+' but found '+$found.Count)};$found[0]}

        # S8: falsy-but-real values are not blank.
        $f=[ordered]@{Desired=[pscustomobject][ordered]@{Name='fixture';EncryptData=$false;QueueLength=0;Description='';Extra=$null};IisPoolSettings=@{queueLength=0;enable32Bit=$false}}
        $rows=@(Get-WsmWizardPreparationForm $f 'SmbShare')
        Check ((Row $rows 'Desired/EncryptData').origin -ceq 'CurrentDraft') 'S8: EncryptData=false was labelled NeedsHumanDecision.'
        Check ((Row $rows 'Desired/QueueLength').origin -ceq 'CurrentDraft') 'S8: an integer 0 was labelled NeedsHumanDecision.'
        Check ((Row $rows 'IisPoolSettings/queueLength').origin -ceq 'CurrentDraft' -and (Row $rows 'IisPoolSettings/enable32Bit').origin -ceq 'CurrentDraft') 'S8: pool settings 0/false were labelled NeedsHumanDecision.'
        Check ((Row $rows 'Desired/Description').origin -ceq 'NeedsHumanDecision' -and (Row $rows 'Desired/Extra').origin -ceq 'NeedsHumanDecision') 'S8 control: empty string and null must stay NeedsHumanDecision.'
        Check (-not (Test-WsmWizardPreparationBlankValue $false) -and -not (Test-WsmWizardPreparationBlankValue 0) -and -not (Test-WsmWizardPreparationBlankValue 0.0) -and -not (Test-WsmWizardPreparationBlankValue ([long]0))) 'S8: the blank-value rule treats false/0/0.0 as empty.'
        Check ((Test-WsmWizardPreparationBlankValue '') -and (Test-WsmWizardPreparationBlankValue $null) -and -not (Test-WsmWizardPreparationBlankValue 'x')) 'S8 control: the blank-value rule must still see empty string and null as empty.'

        # S9: one choice rule for the form and for the bulk preview.
        Check ((Get-WsmWizardPreparationChoiceIssue 'choice' @('A','B') 'C') -ceq 'OutsideOptions' -and (Get-WsmWizardPreparationChoiceIssue 'choice' @('A','B') 'A') -ceq '' -and (Get-WsmWizardPreparationChoiceIssue 'text' @('A','B') 'C') -ceq '') 'S9: the shared choice rule does not separate legal, outside-option and non-choice values.'
        $draft=[ordered]@{Desired=[pscustomobject][ordered]@{Name='fixture-share';Path='C:\data';Description='d';EncryptData=$false;DrainPolicy='ReviewRequired';DrainEvidence='';Access=@()}}
        $drows=@(Get-WsmWizardPreparationForm $draft 'SmbShare')
        $policy=Row $drows 'Desired/DrainPolicy';$evidence=Row $drows 'Desired/DrainEvidence'
        Check ($policy.type -ceq 'choice' -and $policy.required -and $policy.editable -and @($policy.options).Count -eq 2 -and $policy.origin -ceq 'NeedsHumanDecision') 'S9: a DrainPolicy draft outside its options was not a required choice needing a human decision.'
        Check ($evidence.required -and $evidence.editable) 'S9: DrainEvidence was not required.'
        $bulk=@(Get-WsmWizardBulkPreparationEligibility ([pscustomobject]@{Adapter='SmbShare';ManualReviewRequired=$false;MissingTypedFields=@();FormFields=$drows}))
        Check (@($bulk|Where-Object {$_.Field -ceq 'Desired/DrainPolicy'}).Count -ge 1 -and @($bulk|Where-Object {$_.Field -ceq 'Desired/DrainEvidence'}).Count -ge 1) 'S9: the bulk preview did not defer the same DrainPolicy/DrainEvidence the form flags.'
        $good=[ordered]@{Desired=[pscustomobject][ordered]@{Name='fixture-share';Path='C:\data';Description='d';EncryptData=$false;DrainPolicy='BlockNewOpens';DrainEvidence='Owner drained the share';Access=@()}}
        $grows=@(Get-WsmWizardPreparationForm $good 'SmbShare')
        $gpolicy=Row $grows 'Desired/DrainPolicy'
        Check ($gpolicy.type -ceq 'choice' -and $gpolicy.origin -ceq 'CurrentDraft' -and (Row $grows 'Desired/DrainEvidence').origin -ceq 'CurrentDraft') 'S9 control: legal drain values must stay a normal current draft.'
        $gbulk=@(Get-WsmWizardBulkPreparationEligibility ([pscustomobject]@{Adapter='SmbShare';ManualReviewRequired=$false;MissingTypedFields=@();FormFields=$grows}))
        Check (-not @($gbulk|Where-Object {$_.Field -like 'Desired/Drain*'}).Count) 'S9 control: the bulk preview deferred a legal drain draft.'
        # An option-bearing field is a choice even when the draft value is empty.
        $emptyPolicy=@(Get-WsmWizardPreparationForm ([ordered]@{Desired=[pscustomobject][ordered]@{DrainPolicy=''}}) 'SmbShare')
        Check ((Row $emptyPolicy 'Desired/DrainPolicy').type -ceq 'choice' -and (Row $emptyPolicy 'Desired/DrainPolicy').required) 'S9: an empty DrainPolicy was not a required choice.'
        # Agreement table: the form verdict (origin) and the bulk verdict match for each draft value.
        foreach($case in @(@('BlockNewOpens',$false),@('CloseReviewedHandles',$false),@('ReviewRequired',$true),@('block',$true),@('',$true))){
            $r=@(Get-WsmWizardPreparationForm ([ordered]@{Desired=[pscustomobject][ordered]@{DrainPolicy=[string]$case[0];DrainEvidence='evidence'}}) 'SmbShare')
            $formFlags=((Row $r 'Desired/DrainPolicy').origin -ceq 'NeedsHumanDecision')
            $bulkFlags=(@(Get-WsmWizardBulkPreparationEligibility ([pscustomobject]@{Adapter='SmbShare';ManualReviewRequired=$false;MissingTypedFields=@();FormFields=$r})|Where-Object {$_.Field -ceq 'Desired/DrainPolicy'}).Count -gt 0)
            Check ($formFlags -eq [bool]$case[1] -and $bulkFlags -eq [bool]$case[1]) ('S9: form and bulk preview disagree on DrainPolicy="'+[string]$case[0]+'" (form='+$formFlags+', bulk='+$bulkFlags+', expected='+[bool]$case[1]+').')
        }

        # An optional (not required) option-bearing field is judged the same way by both sides.
        foreach($case in @(@('SkipMissedRuns',$false),@('ReviewRequired',$true))){
            $r=@(Get-WsmWizardPreparationForm ([ordered]@{CatchUpPolicy=[string]$case[0]}) 'ScheduledTask')
            $formFlags=((Row $r 'CatchUpPolicy').type -ceq 'choice' -and (Row $r 'CatchUpPolicy').origin -ceq 'NeedsHumanDecision')
            $bulkFlags=(@(Get-WsmWizardBulkPreparationEligibility ([pscustomobject]@{Adapter='ScheduledTask';ManualReviewRequired=$false;MissingTypedFields=@();FormFields=$r})|Where-Object {$_.Field -ceq 'CatchUpPolicy'}).Count -gt 0)
            Check ($formFlags -eq [bool]$case[1] -and $bulkFlags -eq [bool]$case[1]) ('S9: form and bulk preview disagree on CatchUpPolicy="'+[string]$case[0]+'" (form='+$formFlags+', bulk='+$bulkFlags+').')
        }
        # DesiredFinalState keeps the adapter-specific legal values: a Service may be Automatic/Manual.
        $svc=@(Get-WsmWizardPreparationForm ([ordered]@{DesiredFinalState='Automatic'}) 'Service')
        Check ((Row $svc 'DesiredFinalState').origin -ceq 'CurrentDraft' -and (Get-WsmWizardPreparationForm ([ordered]@{DesiredFinalState='Automatic'}) 'IISSite')[0].origin -ceq 'NeedsHumanDecision') 'S9: DesiredFinalState legal values are not adapter-specific (Service Automatic must be legal; IISSite Automatic must not).'

        # S10: the typed IIS identity fields are display-only; only AfterValue is a decision.
        foreach($collection in @('IisConfigChanges','DesiredChanges')){
            $iis=[ordered]@{$collection=@([pscustomobject][ordered]@{FieldPointer='/access/@sslFlags';Operation='SetAttribute';ElementName='access';KeyAttributes=@();AttributeName='sslFlags';BeforeValue='[withheld]';AfterValue='';ValuesWithheld=$true})}
            $irows=@(Get-WsmWizardPreparationForm $iis 'IISSection')
            foreach($name in @('Operation','ElementName','AttributeName','ValuesWithheld','FieldPointer','BeforeValue')){
                Check (-not (Row $irows ($collection+'/0/'+$name)).editable) ('S10: '+$collection+'/0/'+$name+' is editable on the form.')
            }
            Check ((Row $irows ($collection+'/0/AfterValue')).editable) ('S10 control: '+$collection+'/0/AfterValue must stay the editable decision.')
        }
        Write-Output ('PASS Test-WizardPreparationFieldRules checks='+$script:checks+'; empty-value, choice and read-only IIS field rules are shared by the form and bulk preview.')
    }
} finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
}
