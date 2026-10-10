#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-physical-paths-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$drive=$null;foreach($letter in @('Z','Y','X','W','V','U')){if([IO.Directory]::GetLogicalDrives() -notcontains ($letter+':\') -and -not (Get-PSDrive $letter -ErrorAction SilentlyContinue)){$drive=$letter+':';break}};if(-not $drive){throw 'No unused drive for physical alias fixture'}
$subst=Join-Path $env:windir 'System32\subst.exe'
& $subst $drive $root;if($LASTEXITCODE -ne 0){throw 'Fixture alias creation failed'}
try{
    & $module {
        param($Root,$Drive)
        $physical=Get-WsmPhysicalPath $Root;$alias=Get-WsmPhysicalPath ($Drive+'\');if($physical -ine $alias){throw 'SUBST physical identity not resolved'}
        $aliasSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=($Drive+'\');TransferChannel='NonC'}
        if(Test-WsmPathOverlap $physical (Get-WsmPhysicalPath 'C:\')){
            $aliasRejected=$false;try{Assert-WsmAssistiveSourceScope $aliasSpec -Native | Out-Null}catch{if($_.Exception.Message -notmatch 'physical C-volume classification'){throw};$aliasRejected=$true}
            if(-not $aliasRejected){throw 'A real SUBST alias onto C was incorrectly accepted by the NonC channel.'}
        }else{if((Assert-WsmAssistiveSourceScope $aliasSpec -Native).Channel -cne 'NonC'){throw 'Distinct native volume lost its NonC classification.'}}
        $plan=[pscustomobject]@{Items=@([pscustomobject]@{Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=$Root;TargetPath=(Join-Path $Root 'business')}})}
        $blocked=$false;try{Assert-WsmSourceWorkspaceSeparation $plan ($Drive+'\state')}catch{$blocked=$true};if(-not $blocked){throw 'Source state alias collision allowed'}
        $plan.Items+=@([pscustomobject]@{Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=(Join-Path $Root 'other');TargetPath=($Drive+'\business\nested')}})
        $blocked=$false;try{Assert-WsmWorkspaceSeparation $plan ($Root+'-state') TargetPath}catch{$blocked=$true};if(-not $blocked){throw 'Physical target overlap through SUBST allowed'}
        $plan.Items=$plan.Items[0..0];$plan.Items[0].MigrationSpec.SourcePath=Join-Path $Root 'business'
        [void][IO.Directory]::CreateDirectory($plan.Items[0].MigrationSpec.SourcePath)
        $blocked=$false;try{Get-WsmScopeEntries $plan.Items[0].MigrationSpec ($Drive+'\business\package') | Out-Null}catch{if($_.Exception.Message -notmatch 'physical aliases'){throw};$blocked=$true};if(-not $blocked){throw 'Package alias inside business data allowed'}
    } $root $drive
}finally{
    $owned=& $module {param($Root,$Drive)(Get-WsmPhysicalPath $Root) -ieq (Get-WsmPhysicalPath ($Drive+'\'))} $root $drive
    if($owned){& $subst $drive /D;if($LASTEXITCODE -ne 0){throw 'Fixture alias cleanup failed'}}else{throw 'Alias ownership changed; cleanup refused'}
}
Write-Host ('PASS: real SUBST identity, source state/payload collision and physical nested target collision. Evidence: '+$root)
