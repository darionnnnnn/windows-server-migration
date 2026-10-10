#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
& $module {
    $script:checks=0
    function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
    function Reader([string[]]$Answers){$script:answers=New-Object 'System.Collections.Queue';foreach($answer in $Answers){$script:answers.Enqueue($answer)};{param($prompt) if($script:answers.Count -eq 0){throw ('Unexpected prompt: '+$prompt)};[string]$script:answers.Dequeue()}}
    $decisionSchema=@{type='objectArray';required=$true;allowEmpty=$true;schema=@{title='決策';properties=[ordered]@{
        RequirementId=@{type='string';required=$true}
        Decision=@{type='enum';options=@('Pending','Required','NotNeeded');required=$true}
        Owner=@{type='string';required=$true}
        DecisionReason=@{type='string';required=$true}
        DecisionEvidence=@{type='string';required=$true}
    }}}
    $answers=Reader @('2','requirement-1','Required','Owner A','Reason A','Evidence A','requirement-2','NotNeeded','Owner B','Reason B','Evidence B')
    $rows=Read-WsmTextTypedValue 'Decisions' $decisionSchema $answers
    Check ($rows.Count -eq 2 -and $rows[0].RequirementId -ceq 'requirement-1' -and $rows[0].Decision -ceq 'Required' -and $rows[1].DecisionEvidence -ceq 'Evidence B') ('Typed object-array collection did not preserve the exact row schema: '+($rows|ConvertTo-Json -Depth 6 -Compress))
    $emptyAnswers=Reader @('0')
    $empty=Read-WsmTextTypedValue 'Decisions' $decisionSchema $emptyAnswers
    Check ($empty.Count -eq 0) 'A required collection explicitly marked allowEmpty did not accept zero rows.'
    Check (Test-WsmTextApplyConfirmation 'APPLY') 'Exact APPLY confirmation was rejected.'
    Check (-not (Test-WsmTextApplyConfirmation 'apply') -and -not (Test-WsmTextApplyConfirmation 'yes')) 'The text apply gate accepted an imprecise confirmation.'
    foreach($action in @('OsProvidedCapture','OsProvidedBaseline','OsProvidedReview','OsProvidedSubmit')){
        Check (((Get-WsmOperationActions).Contains($action)) -and ([string](Get-WsmTextActionLabel $action)).Length -gt 0) ('OSProvided action missing from the Core typed menu: '+$action)
        Check (([string](Get-WsmTextActionGuidance $action)).Length -gt 0) ('OSProvided action guidance is incomplete: '+$action)
    }
    function Get-WsmCatalog([string]$Workspace,[string]$PairId){[pscustomobject]@{DecisionRevision=23;Assistive=[pscustomobject]@{Revision=91;Selections=[pscustomobject]@{Revision=10}}}}
    Check ((Get-WsmTextCurrentRevision 'DecisionRevision' 'fixture' 'pair' 'Export-WsmAssistiveOsProvidedTaskCapture') -eq 23) 'Capture action did not use the native DecisionRevision.'
    Check ((Get-WsmTextCurrentRevision 'ExpectedDecisionRevision' 'fixture' 'pair' 'Submit-WsmAssistiveOsProvidedReview') -eq 23) 'OSProvided baseline/submit did not use the native DecisionRevision.'
    $script:receivedRequirementArgs=$null
    function script:Get-WsmFleet([string]$Workspace){[pscustomobject]@{Pairs=@([pscustomobject]@{PairId='pair-fixture';TargetName='fixture target'})}}
    function script:Get-WsmCatalog([string]$Workspace,[string]$PairId){[pscustomobject]@{DecisionRevision=23;Assistive=[pscustomobject]@{Revision=91;Selections=[pscustomobject]@{Revision=10}}}}
    function script:Submit-WsmAssistiveGeneralHostRequirementDecisions {
        [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][int]$ExpectedRevision,[Parameter(Mandatory)][string]$ReviewHash,[Parameter(Mandatory)][switch]$Ack,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Decisions)
        $script:receivedRequirementArgs=@{Workspace=$Workspace;PairId=$PairId;ExpectedRevision=$ExpectedRevision;ReviewHash=$ReviewHash;Ack=[bool]$Ack;Decisions=@($Decisions)}
        [pscustomobject]@{Status='FixtureCaptured';DecisionRevision=$ExpectedRevision}
    }
    $fixtureHash='a'*64;$fixtureWorkspace=Join-Path ([IO.Path]::GetTempPath()) ('wsm-text-menu-'+[Guid]::NewGuid().ToString('N'))
    $acceptAnswers=Reader @('3','1','RequirementDecisionSubmit','',$fixtureHash,'yes','1','req-1','Required','fixture owner','review reason','review evidence','APPLY')
    $applied=Invoke-WsmTypedTextOperation -Workspace $fixtureWorkspace -PromptReader $acceptAnswers
    $appliedResult=@($applied | Where-Object {$_.PSObject.Properties['Executed']})|Select-Object -Last 1
    Check ($appliedResult.Executed -and $script:receivedRequirementArgs.ExpectedRevision -eq 23 -and $script:receivedRequirementArgs.ReviewHash -ceq $fixtureHash -and $script:receivedRequirementArgs.Ack -and $script:receivedRequirementArgs.Decisions.Count -eq 1) ('End-to-end typed Core menu did not invoke the native operation with CAS, acknowledgment, and decisions: '+(ConvertTo-Json -InputObject @{Applied=$applied;Captured=$script:receivedRequirementArgs} -Depth 8 -Compress))
    $decision=$script:receivedRequirementArgs.Decisions[0]
    Check ($decision.RequirementId -ceq 'req-1' -and $decision.Decision -ceq 'Required' -and $decision.Owner -ceq 'fixture owner' -and $decision.DecisionReason -ceq 'review reason' -and $decision.DecisionEvidence -ceq 'review evidence') 'End-to-end typed nested row lost native parameter values.'
    $script:receivedRequirementArgs=$null
    $cancelAnswers=Reader @('3','1','RequirementDecisionSubmit','',$fixtureHash,'yes','1','req-1','Required','fixture owner','review reason','review evidence','apply')
    $cancelled=Invoke-WsmTypedTextOperation -Workspace $fixtureWorkspace -PromptReader $cancelAnswers
    $cancelledResult=@($cancelled | Where-Object {$_.PSObject.Properties['Executed']})|Select-Object -Last 1
    Check (-not $cancelledResult.Executed -and $cancelledResult.Status -ceq 'Cancelled' -and $null -eq $script:receivedRequirementArgs) 'Typed Core menu invoked the operation without exact APPLY.'
    Write-Output ('PASS: Core typed text forms, required/empty arrays, exact APPLY gate, schema converter and safe credential/cancellation wiring ('+$script:checks+' checks).')
}
