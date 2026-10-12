#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-wrp-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root)
        # Substitute only the native machine observation; all material writers/readers are real.
        $script:receivedFixtureFingerprint=('a'*64)
        function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:receivedFixtureFingerprint;Name='received-plan-fixture';OS='Fixture Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        $sourceRoot=Join-Path $Root 'source-work';$targetRoot=Join-Path $Root 'target-work';$managerRoot=Join-Path $Root 'manager'
        $sourceEnrollment=Initialize-WsmOutputWorkspace $sourceRoot Source
        $script:receivedFixtureFingerprint=('b'*64)
        $targetEnrollment=Initialize-WsmOutputWorkspace $targetRoot Target
        $targetIdentityPath=Join-Path (Join-Path $targetRoot ('targets\'+$targetEnrollment.HostId)) 'target-identity.json'
        $targetIdentityHash=(Get-FileHash -LiteralPath $targetIdentityPath -Algorithm SHA256).Hash
        $source=[pscustomobject]@{HostId=$sourceEnrollment.HostId;Fingerprint=('a'*64);Name='fixture-old-computer'}
        $data=Join-Path $Root 'source-data';[void][IO.Directory]::CreateDirectory($data);[IO.File]::WriteAllText((Join-Path $data 'config.ini'),'actual fixture')
        $item=New-WsmItem $source.HostId Storage DataRoot 'Reviewed fixture folder' 'fixture-folder' @{Path=$data}
        $inventory=New-WsmInventory $source 1 @($item);$inventoryPath=Join-Path $Root 'inventory.json';Write-WsmJson $inventoryPath $inventory
        Initialize-WsmWorkspace $managerRoot|Out-Null
        $catalog=Import-WsmInventory $managerRoot $inventoryPath (Get-FileHash -LiteralPath $inventoryPath).Hash 'fixture-new-computer'
        $spec=[pscustomobject]@{Adapter='FileScope';SourcePath=$data;TargetPath=(Join-Path $Root 'restored');ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='AllowAutoInheritedUpgrade';ConflictPolicy='ReplaceOwned';Owner='Fixture owner';Evidence='isolated fixture scope review';BusinessChecks=@('Fixture content readback')}
        $specPath=Join-Path $Root 'spec.json';Write-WsmJson $specPath $spec
        Set-WsmMigrationSpec $managerRoot $catalog.PairId $item.ItemId $specPath (Get-FileHash -LiteralPath $specPath).Hash 0
        Set-WsmDecision $managerRoot $catalog.PairId @($item.ItemId) Include 'fixture intent' 1|Out-Null
        $planPath=Join-Path $Root 'plan.json';$approval=Approve-WsmMigrationPlan $managerRoot $catalog.PairId $targetIdentityPath $targetIdentityHash $planPath 2 ISOLATED-PILOT
        foreach($role in @('Source','Target')){
            $work=if($role -ceq 'Source'){$sourceRoot}else{$targetRoot}
            $script:receivedFixtureFingerprint=if($role -ceq 'Source'){('a'*64)}else{('b'*64)}
            $import=Import-WsmWizardApprovedPlan $work $role $planPath $approval.SHA256
            if($import.Status -cne 'ImportedVerified' -or $import.PairId -cne $catalog.PairId){throw 'Actual sealed plan import failed.'}
            $profile=Read-WsmOutputProfile $work
            $received=Get-WsmWizardReceivedApprovedPlan $work $catalog.PairId $profile
            if(-not $received -or $received.SHA256 -ine $approval.SHA256){throw 'Full received-plan lookup lost a valid receipt (including regex auto-variable collision).'}
            $choices=@(Get-WsmWizardReceivedPlanChoices $work $profile)
            if($choices.Count -ne 1 -or $choices[0].pairId -cne $catalog.PairId){throw 'Verified received plan is not selectable.'}
            $projection=Get-WsmWizardProjection $work $catalog.PairId $role
            if(-not $projection.readiness.targetBoundApproval){throw 'Full projection did not recognize actual bound approval.'}
            $action=if($role -ceq 'Source'){'ExportPackage'}else{'RestorePreview'}
            $defaults=Get-WsmWizardActionDefaults $work $catalog.PairId $role $action
            if($role -ceq 'Source' -and ($defaults.args.ExpectedHash -ine $approval.SHA256 -or -not $defaults.args.PlanPath)){throw 'Source defaults lost the trusted plan binding.'}
            if([IO.Directory]::Exists((Join-Path $work 'catalogs'))){throw 'Received plan projection fabricated a Manager catalog.'}
            $blocked=$false;try{Import-WsmWizardApprovedPlan $work $role $planPath ('0'*64)|Out-Null}catch{$blocked=$true};if(-not $blocked){throw 'Wrong independent hash was accepted.'}
        }
        $script:receivedFixtureFingerprint=('a'*64)
        $longWork=Join-Path $Root ('source-'+('x'*40))
        $longEnrollment=Initialize-WsmOutputWorkspace $longWork Source
        $longSource=[pscustomobject]@{HostId=$longEnrollment.HostId;Fingerprint=('a'*64);Name='long-root-source'}
        $longItem=New-WsmItem $longSource.HostId Storage DataRoot 'Long-root fixture' 'long-root-folder' @{Path=$data}
        $longInventoryPath=Join-Path $Root 'long-inventory.json';Write-WsmJson $longInventoryPath (New-WsmInventory $longSource 1 @($longItem))
        $longManager=Join-Path $Root 'long-manager';Initialize-WsmWorkspace $longManager|Out-Null
        $longCatalog=Import-WsmInventory $longManager $longInventoryPath (Get-FileHash -LiteralPath $longInventoryPath).Hash 'fixture-new-computer'
        Set-WsmMigrationSpec $longManager $longCatalog.PairId $longItem.ItemId $specPath (Get-FileHash -LiteralPath $specPath).Hash 0
        Set-WsmDecision $longManager $longCatalog.PairId @($longItem.ItemId) Include 'fixture intent' 1|Out-Null
        $longPlanPath=Join-Path $Root 'long-plan.json'
        $longApproval=Approve-WsmMigrationPlan $longManager $longCatalog.PairId $targetIdentityPath $targetIdentityHash $longPlanPath 2 ISOLATED-PILOT
        $longRejected=$false
        try{Import-WsmWizardApprovedPlan $longWork Source $longPlanPath $longApproval.SHA256|Out-Null}catch{$longRejected=$_.Exception.Message -match 'too long'}
        if(-not $longRejected -or [IO.Directory]::Exists((Join-Path $longWork 'workspace-control\wizard-materials\received-plans'))){throw 'Long received-plan paths were not rejected before material directory creation.'}
        $script:receivedFixtureFingerprint=('c'*64)
        if(Get-WsmWizardReceivedApprovedPlan $sourceRoot $catalog.PairId (Read-WsmOutputProfile $sourceRoot)){throw 'A different local host could use the received plan.'}
        Write-Host 'PASS: real core-sealed plan, both enrolled role imports, full receipt lookup/pair choice/projection/defaults, no fabricated catalogs, wrong hash and changed host rejected.'
    } $root
} finally {
    $full=[IO.Path]::GetFullPath($root);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike 'wsm-wrp-*'){throw 'Unsafe cleanup path.'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
