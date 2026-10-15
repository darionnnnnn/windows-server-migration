#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../src/WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
& $module {
    # Isolated reader/CAS wrapper contract; not a package or host acceptance.
    $script:readRevision=4;$script:changeDuringRead=$false
    function script:Get-WsmHtmlRevisionVector($Workspace,$PairId){[pscustomobject]@{revision=$script:readRevision;decisionRevision=$script:readRevision;selectionRevision=2;sourceSelectionRevision=2;dataVersion=('a'*64);pairId=$PairId}}
    function script:Get-WsmWizardRuntimeProjection($Workspace,$PairId,$Role,$Jobs){if($script:changeDuringRead){$script:readRevision++};[pscustomobject]@{Kind='WizardRuntimeProjection';Role=$Role;PairId=$PairId;status='FixtureRead';AuthoritativeApproval=$false}}
    $read=Get-WsmHtmlWizardRuntime 'C:\fixture' 'fixture-pair' Target @{}
    if($read.viewContext.revision -ne 4 -or $read.viewContext.dataVersion -cne ('a'*64) -or $read.AuthoritativeApproval){throw 'Runtime read did not carry its exact reviewed CAS vector.'}
    $script:changeDuringRead=$true;$rejected=$false
    try{Get-WsmHtmlWizardRuntime 'C:\fixture' 'fixture-pair' Target @{}|Out-Null}catch{$rejected=$_.Exception.Message -match 'Review changed: runtime materials changed'}
    if(-not $rejected){throw 'Runtime read returned usable actions after its context changed mid-read.'}
    Write-Output 'PASS runtime reviewed-context reader and mid-read invalidation contract; isolated wrapper only.'
}
