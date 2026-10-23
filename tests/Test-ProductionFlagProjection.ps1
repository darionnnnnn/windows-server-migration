#requires -Version 5.1
# P1: every projection that copies ProductionVerified / ProductionQualified from a source object must emit $false,
# whatever the source says (true, "true", 1). Absent fields must not be invented unless the projection always emits them.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
$script:checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Has($Object,[string]$Name){return [bool]($Object -and $Object.PSObject.Properties[$Name])}
function IsFalse($Value){return ($Value -is [bool] -and $Value -eq $false)}
$dirty=@(@('bool true',$true),@('string "true"','true'),@('int 1',1))
try {
    # 1. ConvertTo-WsmWizardHtmlValue (modern projection, WizardHtmlRuntime $allowed copy).
    foreach($case in $dirty){
        $view=& $module {param($v)ConvertTo-WsmWizardHtmlValue ([pscustomobject]@{Status='Recorded';ProductionVerified=$v;ProductionQualified=$v})} $case[1]
        Check (Has $view 'ProductionVerified') ('Wizard projection dropped ProductionVerified for '+$case[0]+'.')
        Check (IsFalse $view.ProductionVerified) ('Wizard projection copied ProductionVerified from '+$case[0]+'.')
        Check (-not (Has $view 'ProductionQualified') -or (IsFalse $view.ProductionQualified)) ('Wizard projection copied ProductionQualified from '+$case[0]+'.')
        $nested=& $module {param($v)ConvertTo-WsmWizardHtmlValue ([pscustomobject]@{result=[pscustomobject]@{ProductionVerified=$v}})} $case[1]
        Check (IsFalse $nested.result.ProductionVerified) ('Nested wizard projection copied ProductionVerified from '+$case[0]+'.')
    }
    $clean=& $module {ConvertTo-WsmWizardHtmlValue ([pscustomobject]@{Status='Recorded';ProductionVerified=$false})}
    Check (IsFalse $clean.ProductionVerified) 'Wizard projection changed a false ProductionVerified.'
    $absent=& $module {ConvertTo-WsmWizardHtmlValue ([pscustomobject]@{Status='Recorded'})}
    Check (-not (Has $absent 'ProductionVerified') -and -not (Has $absent 'ProductionQualified')) 'Wizard projection invented a Production flag.'

    # 2. Get-WsmHtmlResultProjection ($fields copy plus modern projection merge).
    foreach($case in $dirty){
        $out=@(& $module {param($v)Get-WsmHtmlResultProjection @([pscustomobject]@{Status='Recorded';ProductionVerified=$v;ProductionQualified=$v})} $case[1])[0]
        Check (IsFalse $out.ProductionVerified) ('Result projection copied ProductionVerified from '+$case[0]+'.')
        Check (IsFalse $out.ProductionQualified) ('Result projection copied ProductionQualified from '+$case[0]+'.')
    }
    $out=@(& $module {Get-WsmHtmlResultProjection @([pscustomobject]@{Status='Recorded';ProductionVerified=$false;ProductionQualified=$false})})[0]
    Check ((IsFalse $out.ProductionVerified) -and (IsFalse $out.ProductionQualified)) 'Result projection changed false flags.'
    $out=@(& $module {Get-WsmHtmlResultProjection @([pscustomobject]@{Status='Recorded'})})[0]
    Check (-not (Has $out 'ProductionVerified') -and -not (Has $out 'ProductionQualified')) 'Result projection invented a Production flag.'
    $waiting=@(& $module {Get-WsmHtmlResultProjection @([pscustomobject]@{Status='WaitingForInput';RequiredSecretRefs=@();ParentOperationId='op-1';PreviewHash=('a'*64);NoTargetWrites=$true;ResumeRequired=$true;ProductionVerified=$true})})[0]
    Check (IsFalse $waiting.ProductionVerified) 'WaitingForInput projection did not emit a fixed false ProductionVerified.'

    # 3. ConvertTo-WsmHtmlPublicJobRecord (DeveloperProbe outputs whitelist copy).
    foreach($case in $dirty){
        $record=[pscustomobject]@{jobId='job-1';action='DeveloperProbe';outputs=@([pscustomobject]@{Status='Recorded';ProductionQualified=$case[1];BusinessValidated=$false;ProductionVerified=$case[1]})}
        $public=& $module {param($r)ConvertTo-WsmHtmlPublicJobRecord $r} $record
        Check (IsFalse @($public.outputs)[0].ProductionQualified) ('DeveloperProbe public job copied ProductionQualified from '+$case[0]+'.')
        Check (-not (Has @($public.outputs)[0] 'ProductionVerified') -or (IsFalse @($public.outputs)[0].ProductionVerified)) ('DeveloperProbe public job copied ProductionVerified from '+$case[0]+'.')
    }
    $record=[pscustomobject]@{jobId='job-1';action='DeveloperProbe';outputs=@([pscustomobject]@{Status='Recorded'})}
    $public=& $module {param($r)ConvertTo-WsmHtmlPublicJobRecord $r} $record
    Check (-not (Has @($public.outputs)[0] 'ProductionQualified')) 'DeveloperProbe public job invented ProductionQualified.'

    # 3b. Any other job's stored outputs (e.g. an older job file that was never projected) are forced to false as well.
    foreach($case in $dirty){
        $record=[pscustomobject]@{jobId='job-2';action='StartBackup';outputs=@([pscustomobject]@{Status='Succeeded';ProductionVerified=$case[1];ProductionQualified=$case[1]})}
        $public=& $module {param($r)ConvertTo-WsmHtmlPublicJobRecord $r} $record
        Check ((IsFalse @($public.outputs)[0].ProductionVerified) -and (IsFalse @($public.outputs)[0].ProductionQualified)) ('Stored job outputs copied a Production flag from '+$case[0]+'.')
        Check ($record.outputs[0].ProductionVerified -eq $case[1]) 'The public projection must not mutate the stored job record.'
    }
    $public=& $module {param($r)ConvertTo-WsmHtmlPublicJobRecord $r} ([pscustomobject]@{jobId='job-3';action='StartBackup';outputs=@([pscustomobject]@{Status='Succeeded'})})
    Check (-not (Has @($public.outputs)[0] 'ProductionVerified')) 'Stored job outputs invented ProductionVerified.'

    # 4. WindowsSettingsReview preview hash projection: a forged flag must not change what is bound.
    $makePreview={param($flag,[bool]$withFlag)
        $p=[ordered]@{SchemaVersion=1;Kind='WindowsSettingsReviewPreview';PairId='pair-1';ReviewWindowsSettings=$true;SourceFingerprint='s';TargetFingerprint='t';SourceInventoryHash=('a'*64);TargetInventoryHash=('b'*64);SourceRevision=1;TargetRevision=2;Rows=@();Coverage=@();TargetCoverage=@();RequiredConsumerBlockers=@();AuthoritativeApproval=$false;ReadinessProof=$false}
        if($withFlag){$p.ProductionQualified=$flag}
        [pscustomobject]$p}
    $baseline=& $module {param($p)Get-WsmWindowsSettingsPreviewHash $p} (& $makePreview $false $true)
    foreach($case in $dirty){
        $hash=& $module {param($p)Get-WsmWindowsSettingsPreviewHash $p} (& $makePreview $case[1] $true)
        Check ($hash -ceq $baseline) ('Windows settings preview hash bound a forged ProductionQualified ('+$case[0]+').')
    }
    $hashAbsent=& $module {param($p)Get-WsmWindowsSettingsPreviewHash $p} (& $makePreview $null $false)
    Check ($hashAbsent -ceq $baseline) 'Windows settings preview hash changed when ProductionQualified is absent.'

    # 5. Overview provenance / delivery step: copy of the delivery summary flag.
    $sealed=[pscustomobject]@{ApprovalId='approval-fixture';PlanHash=('e'*64);SourceHostId='source';TargetHostId='target';Generation=3;Status='Sealed';Mode='File';VolumeCount=1;TotalVolumeBytes=1024;TransportHash=('f'*64);DeliveryId='delivery-fixture'}
    $catalog=[pscustomobject]@{PairId='pair-delivery';Items=@();Approval=[pscustomobject]@{ApprovalId='approval-fixture';Hash=('e'*64);TargetHostId='target';Kind='MigrationPlan'};Source=[pscustomobject]@{HostId='source'};Target=[pscustomobject]@{HostId='target'};Generation=3;DeliveryReceipts=@($sealed);Assistive=[pscustomobject]@{Revision=1;Selections=[pscustomobject]@{Revision=1;Items=@()}}}
    $stage=[pscustomobject]@{Latest=[pscustomobject]@{PayloadGeneration=3;Stage='Restore';Status='ReviewRequired';ProducedUtc='2026-10-10T00:00:00Z';Assistive=[pscustomobject]@{ItemResults=@();FileResults=@()}};AllCurrent=@()}
    foreach($case in $dirty){
        $overview=& $module {
            param($catalog,$stage,$flag)
            $real=Get-WsmDeliveryReceiptSummary $catalog
            $forged=[ordered]@{}
            foreach($property in $real.PSObject.Properties){$forged[$property.Name]=$property.Value}
            $forged.ProductionVerified=$flag
            $script:forgedDelivery=[pscustomobject]$forged
            function Get-WsmDeliveryReceiptSummary($Catalog){$script:forgedDelivery}
            Get-WsmHtmlOverviewProjection $catalog $stage @{} 'Manager' 1
        } $catalog $stage $case[1]
        $step=@($overview.steps|Where-Object id -CEQ 'delivery')[0]
        Check (IsFalse $step.productionVerified) ('Overview delivery step copied productionVerified from '+$case[0]+'.')
        Check (IsFalse $overview.provenance.deliveryProductionVerified) ('Overview provenance copied deliveryProductionVerified from '+$case[0]+'.')
    }

    # 6. Static consumer guard for console.js: the job output renderer must not turn the flag into a yes.
    $ui=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\src\ui\console.js'),[Text.Encoding]::UTF8)
    Check ($ui.Contains("if(key==='ProductionVerified'||key==='ProductionQualified')return ")) 'console.js job output renderer can still show a yes for the production flags.'

    Write-Output ('PASS Test-ProductionFlagProjection checks='+$script:checks+'; projections force false for true, "true" and 1; absent fields are not invented.')
} finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
}
