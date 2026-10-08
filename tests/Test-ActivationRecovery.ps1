#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-activation-'+[Guid]::NewGuid().ToString('N'))
& $module {
    param($Root)
    $pair=[Guid]::NewGuid().ToString();$ids=@(('a'*64),('b'*64));$script:activationModes=@{};$script:activationCalls=@{};$script:failActivation=$true
    $items=@(foreach($id in $ids){$script:activationModes[$id]='Staged';$script:activationCalls[$id]=0;[pscustomobject]@{ItemId=$id;Decision='Include';Dependencies=@();MigrationSpec=[pscustomobject]@{Adapter='Service';Desired=[pscustomobject]@{Name=$id};DesiredFinalState='Running'}}})
    $package=[pscustomobject]@{Manifest=[pscustomobject]@{PairId=$pair;BatchId=[Guid]::NewGuid().ToString();PlanHash=('d'*64);Target=[pscustomobject]@{Fingerprint=('e'*64)}};Plan=[pscustomobject]@{Items=$items}}
    $paths=Get-WsmOperationPaths $Root $pair;$state=Get-WsmOperationState $paths $package;$state.ManifestHash='c'*64;$state.Items=@(foreach($id in $ids){[pscustomobject]@{ItemId=$id;CreatedByTool=$true;Status='Succeeded'}})
    $state.Cutover=[pscustomobject]@{Stage='NetworkApplied';NewTransactionsPossible=$true};Add-WsmJournal $paths $state CutoverPrepared '' $state.Cutover
    function script:Get-WsmAdapterState {param($Spec)[pscustomobject]@{Exists=$true;Mode=$script:activationModes[$Spec.Desired.Name]}}
    function script:Test-WsmAdapterConfiguration {param($Spec,$Phase)[pscustomobject]@{Passed=($script:activationModes[$Spec.Desired.Name] -ceq $Phase)}}
    function script:Invoke-WsmAdapterActivation {param($Spec,$Enable,$Ownership)$id=$Spec.Desired.Name;$script:activationCalls[$id]++;$checkpoint=Read-WsmJson $script:activationPaths.State;if(-not @($checkpoint.Cutover.Activations | Where-Object {$_.ItemId -ceq $id -and $_.Status -ceq 'Intent'}).Count){throw 'Native activation preceded durable intent'};$script:activationModes[$id]='Final';if($script:failActivation){$script:failActivation=$false;throw 'Injected termination after native effect'}}
    $script:activationPaths=$paths;$failed=$false;try{Invoke-WsmActivationSequence $package $paths $state}catch{$failed=$true};if(-not $failed -or -not $state.Cutover.NewTransactionsPossible){throw 'Activation interruption lost transaction boundary'}
    $state=Read-WsmJson $paths.State;Invoke-WsmActivationSequence $package $paths $state -Resume
    if(@($state.Cutover.Activations | Where-Object Status -NE Completed).Count -or $script:activationCalls[$ids[0]] -ne 1 -or $script:activationCalls[$ids[1]] -ne 1){throw 'Resume replayed activated producer or lost next item'}
    Invoke-WsmActivationSequence $package $paths $state -Resume;if($script:activationCalls[$ids[0]] -ne 1){throw 'Completed checkpoint reactivated producer'}
    $script:activationModes[$ids[0]]='Drift';$blocked=$false;try{Invoke-WsmActivationSequence $package $paths $state -Resume}catch{$blocked=$true};if(-not $blocked){throw 'Activated drift bypassed reconciliation'}
    $state.Cutover.Activations[0].Status='Intent';$blocked=$false;try{Invoke-WsmActivationSequence $package $paths $state -Resume}catch{$blocked=$true};if(-not $blocked -or $script:activationCalls[$ids[0]] -ne 1){throw 'Ambiguous partial native state replayed'}
    $script:activationModes[$ids[0]]='Staged';$state.Cutover.Activations[0].BeforeHash='f'*64;$blocked=$false;try{Invoke-WsmActivationSequence $package $paths $state -Resume}catch{$blocked=$true};if(-not $blocked -or $script:activationCalls[$ids[0]] -ne 1){throw 'Staged configuration mismatch with durable before hash replayed'}
    $blocked=$false;try{Invoke-WsmActivationSequence $package $paths $state}catch{$blocked=$true};if(-not $blocked){throw 'Existing intent resumed without explicit Resume'}
    $fileItem=[pscustomobject]@{ItemId=('e'*64);MigrationSpec=[pscustomobject]@{Adapter='FileScope';TargetPath='C:\Fixture\target'}};$fileOwnership=[pscustomobject]@{ActualHash=('a'*64)}
    function script:Test-WsmFileScope {param($Item,$Package,$Target,$SidMap)[pscustomobject]@{Passed=$true;ActualHash=('b'*64)}}
    if(Test-WsmActivationPhase $fileItem $fileOwnership Final $package $state){throw 'File activation ignored owned target digest mismatch'}
    function script:Test-WsmFileScope {param($Item,$Package,$Target,$SidMap)[pscustomobject]@{Passed=$true;ActualHash=('a'*64)}}
    if(-not (Test-WsmActivationPhase $fileItem $fileOwnership Final $package $state)){throw 'Exact owned file activation proof rejected'}
    $manualItem=[pscustomobject]@{ItemId=('f'*64);MigrationSpec=[pscustomobject]@{Adapter='ManualWorkflow'}};function script:Test-WsmEvidence {param($State,$ItemId,$Check,$Hash)$false}
    if(Test-WsmActivationPhase $manualItem $fileOwnership Final $package $state){throw 'Manual workflow activation without restore evidence accepted'}
} $root
Write-Host ('PASS: durable activation intent, native-effect interruption, exact final adoption, next-item resume, no repeated activation, ambiguous/drift refusal. Native APIs are fixtures. Evidence: '+$root)
