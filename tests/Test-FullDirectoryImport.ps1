#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
function Assert-DirectoryImport([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-di-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root);$resolvedRoot=[IO.Path]::GetFullPath($root)
$ownedTargetRoots=New-Object 'System.Collections.Generic.List[string]'
function New-DirectoryImportTargetRoot {
    $volume=[IO.Path]::GetPathRoot([IO.Path]::GetTempPath());$path=Join-Path $volume ('i-'+[Guid]::NewGuid().ToString('N'));$ownedTargetRoots.Add($path);return $path
}
try{
    $sourcePath=Join-Path $root 'source-data';[void][IO.Directory]::CreateDirectory($sourcePath)
    [IO.File]::WriteAllText((Join-Path $sourcePath 'unicode-中文.txt'),'directory delivery payload')
    $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString('D');Fingerprint=('a'*64);Name='fixture-source'}
    $item=New-WsmItem $source.HostId Storage DataRoot 'Directory import data' 'directory-import-root' @{Path=$sourcePath}
    $inventory=New-WsmInventory $source 1 @($item);$inventoryPath=Join-Path $root 'inventory.json';[IO.File]::WriteAllText($inventoryPath,($inventory | ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)))
    $manager=Join-Path $root 'manager';Initialize-WsmWorkspace $manager | Out-Null
    $catalog=Import-WsmInventory $manager $inventoryPath (Get-FileHash -LiteralPath $inventoryPath).Hash 'directory-import-target';$pair=$catalog.PairId
    & $module {param($Path)$script:fixtureInventory=$Path;$script:fixtureFingerprint=('b'*64);function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:fixtureFingerprint;Name='fixture-target';OS='Windows Server fixture';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}};function script:Export-WsmInventory {param($OutputDirectory)[pscustomobject]@{Path=$script:fixtureInventory;SHA256=(Get-FileHash -LiteralPath $script:fixtureInventory -Algorithm SHA256).Hash}}} $inventoryPath
    $targetState=Join-Path $root 'target-state';$targetIdentityPath=Join-Path $root 'target-identity.json';$targetIdentity=Register-WsmTarget $targetState $targetIdentityPath
    $spec=[pscustomobject]@{Adapter='FileScope';SourcePath=$sourcePath;TargetPath=(Join-Path $root 'restored-data');ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='AllowAutoInheritedUpgrade';ConflictPolicy='ReplaceOwned';Owner='Directory import fixture';Evidence='approved fixture scope';BusinessChecks=@('fixture readback')}
    $specPath=Join-Path $root 'scope.json';[IO.File]::WriteAllText($specPath,($spec | ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
    Set-WsmMigrationSpec $manager $pair $item.ItemId $specPath (Get-FileHash -LiteralPath $specPath).Hash 0
    Set-WsmDecision $manager $pair @($item.ItemId) Include 'approved directory fixture' 1 | Out-Null
    $planPath=Join-Path $root 'plan.json';$approval=Approve-WsmMigrationPlan $manager $pair $targetIdentity.Path $targetIdentity.SHA256 $planPath 2 ISOLATED-PILOT
    & $module {$script:fixtureFingerprint=('a'*64)}
    $sourceState=Join-Path $root 'source-state';[void][IO.Directory]::CreateDirectory($sourceState)
    $packageRoot=Join-Path $root 'package-work';$package=Export-WsmMigrationPackage $planPath $approval.SHA256 $sourceState $packageRoot -ChunkBytes 65536
    $deliveryPath=Join-Path $root 'original-delivery';$delivery=Export-WsmDirectoryDelivery $package.ManifestPath $package.SHA256 $deliveryPath
    $summaryHash=(Get-FileHash -LiteralPath $delivery.SummaryPath -Algorithm SHA256).Hash.ToLowerInvariant()

    # Relocation is intentional: the summary's original absolute PackageDirectory is not authoritative.
    $relocated=Join-Path $root 'relocated delivery';Copy-Item -LiteralPath $deliveryPath -Destination $relocated -Recurse
    & $module {$script:fixtureFingerprint=('b'*64)}
    $targetRoot=New-DirectoryImportTargetRoot;Initialize-WsmOutputWorkspace $targetRoot Target -Mode Directory | Out-Null
    $imported=Import-WsmDirectoryDelivery -SummaryPath $delivery.SummaryPath -ExpectedSummaryHash $summaryHash -SourceDirectory $relocated -WorkRoot $targetRoot -AttemptId '7a1b940f-9326-4abd-a996-c147b513a8a1'
    Assert-DirectoryImport ($imported.Valid -and $imported.PairId -ceq $pair -and $imported.PlanHash -ieq $approval.SHA256) 'Relocated directory delivery did not retain approved package identity.'
    Assert-DirectoryImport ((Test-WsmMigrationPackage $imported.ManifestPath $imported.ManifestHash).Valid) 'Imported target package failed normal package validation.'
    $targetMembers=@(Get-ChildItem -LiteralPath $imported.Directory -File -Recurse | ForEach-Object {$_.FullName.Substring($imported.Directory.Length).TrimStart('\').Replace('\','/')})
    Assert-DirectoryImport ($targetMembers.Count -eq [int]$delivery.Members -and -not ($targetMembers -match 'summary|export-state|journal|raw')) 'Incoming directory contains data outside the clean package member set.'
    Assert-DirectoryImport (-not ([IO.Path]::GetFullPath($delivery.SummaryPath).StartsWith([IO.Path]::GetFullPath($imported.Directory).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))) 'Target incoming package adopted the external summary path.'

    $longWorkRoot=Join-Path $root ('long-'+('x'*30));Initialize-WsmOutputWorkspace $longWorkRoot Target -Mode Directory | Out-Null
    $rejected=$false;$longError='';try{Import-WsmDirectoryDelivery $delivery.SummaryPath $summaryHash $relocated $longWorkRoot | Out-Null}catch{$rejected=$true;$longError=$_.Exception.Message}
    Assert-DirectoryImport ($rejected -and $longError -match 'MAX_PATH') 'Overlong target member path was not rejected by the preflight bound.'
    Assert-DirectoryImport (-not [IO.Directory]::Exists((Join-Path $longWorkRoot ('pairs\'+$pair))) -and -not [IO.Directory]::Exists((Join-Path $longWorkRoot 'workspace-control\directory-imports'))) 'MAX_PATH rejection registered a pair or created an incoming staging directory.'

    $cancelTargetRoot=New-DirectoryImportTargetRoot;Initialize-WsmOutputWorkspace $cancelTargetRoot Target -Mode Directory | Out-Null
    $wrongToken=New-WsmCancellationToken $pair $approval.SHA256 $package.SHA256 ([Guid]::NewGuid().ToString('D')) (Join-Path $cancelTargetRoot 'wrong-scope')
    $rejected=$false;try{Import-WsmDirectoryDelivery $delivery.SummaryPath $summaryHash $relocated $cancelTargetRoot -CancellationToken $wrongToken | Out-Null}catch{$rejected=$true}
    Assert-DirectoryImport ($rejected -and -not [IO.Directory]::Exists((Join-Path $cancelTargetRoot ('pairs\'+$pair)))) 'Wrong-scope cancellation control was accepted or registered a pair.'

    $wrongKindPath=Join-Path $root 'wrong-kind.json';$wrongKind=Get-Content -LiteralPath $delivery.SummaryPath -Raw | ConvertFrom-Json;$wrongKind.Kind='PackageTransport';[IO.File]::WriteAllText($wrongKindPath,($wrongKind | ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)));$wrongKindHash=(Get-FileHash -LiteralPath $wrongKindPath).Hash
    $wrongKindTarget=New-DirectoryImportTargetRoot;Initialize-WsmOutputWorkspace $wrongKindTarget Target -Mode Directory | Out-Null
    $rejected=$false;try{Import-WsmDirectoryDelivery $wrongKindPath $wrongKindHash $relocated $wrongKindTarget | Out-Null}catch{$rejected=$true}
    Assert-DirectoryImport $rejected 'Wrong-kind directory summary was accepted.'
    Assert-DirectoryImport (-not [IO.Directory]::Exists((Join-Path $wrongKindTarget ('pairs\'+$pair)))) 'Wrong-kind rejection registered a target pair.'

    $badHashTarget=New-DirectoryImportTargetRoot;Initialize-WsmOutputWorkspace $badHashTarget Target -Mode Directory | Out-Null
    $rejected=$false;try{Import-WsmDirectoryDelivery $delivery.SummaryPath ('0'*64) $relocated $badHashTarget | Out-Null}catch{$rejected=$true}
    Assert-DirectoryImport $rejected 'A tampered summary hash was accepted.'
    Assert-DirectoryImport (-not [IO.Directory]::Exists((Join-Path $badHashTarget ('pairs\'+$pair)))) 'Summary hash rejection registered a target pair.'

    $tampered=Join-Path $root 'tampered-delivery';Copy-Item -LiteralPath $deliveryPath -Destination $tampered -Recurse;[IO.File]::AppendAllText((Join-Path $tampered 'plan.json'),' ')
    $tamperTarget=New-DirectoryImportTargetRoot;Initialize-WsmOutputWorkspace $tamperTarget Target -Mode Directory | Out-Null
    $rejected=$false;try{Import-WsmDirectoryDelivery $delivery.SummaryPath $summaryHash $tampered $tamperTarget | Out-Null}catch{$rejected=$true}
    Assert-DirectoryImport $rejected 'Tampered package member was accepted.'
    Assert-DirectoryImport (-not [IO.Directory]::Exists((Join-Path $tamperTarget ('pairs\'+$pair))) -and @(Get-ChildItem -LiteralPath (Join-Path $tamperTarget 'workspace-control') -Directory -Filter 'directory-imports').Count -eq 0) 'Tamper rejection left an incoming tree or registered pair.'

    $extra=Join-Path $root 'extra-delivery';Copy-Item -LiteralPath $deliveryPath -Destination $extra -Recurse;[IO.File]::WriteAllText((Join-Path $extra 'export-state.json'),'not deliverable')
    $extraTarget=New-DirectoryImportTargetRoot;Initialize-WsmOutputWorkspace $extraTarget Target -Mode Directory | Out-Null
    $rejected=$false;try{Import-WsmDirectoryDelivery $delivery.SummaryPath $summaryHash $extra $extraTarget | Out-Null}catch{$rejected=$true}
    Assert-DirectoryImport $rejected 'Extra package member was accepted.'
    Assert-DirectoryImport (-not [IO.Directory]::Exists((Join-Path $extraTarget ('pairs\'+$pair))) -and @(Get-ChildItem -LiteralPath (Join-Path $extraTarget 'workspace-control') -Directory -Filter 'directory-imports').Count -eq 0) 'Extra-member rejection left an incoming tree or registered pair.'

    $missing=Join-Path $root 'missing-delivery';Copy-Item -LiteralPath $deliveryPath -Destination $missing -Recurse;[IO.File]::Delete((Join-Path $missing 'plan.json'))
    $missingTarget=New-DirectoryImportTargetRoot;Initialize-WsmOutputWorkspace $missingTarget Target -Mode Directory | Out-Null
    $rejected=$false;try{Import-WsmDirectoryDelivery $delivery.SummaryPath $summaryHash $missing $missingTarget | Out-Null}catch{$rejected=$true}
    Assert-DirectoryImport $rejected 'Missing package member was accepted.'
    Assert-DirectoryImport (-not [IO.Directory]::Exists((Join-Path $missingTarget ('pairs\'+$pair))) -and @(Get-ChildItem -LiteralPath (Join-Path $missingTarget 'workspace-control') -Directory -Filter 'directory-imports').Count -eq 0) 'Missing-member rejection left an incoming tree or registered pair.'

    & $module {$script:fixtureFingerprint=('c'*64)}
    $wrongTargetRoot=New-DirectoryImportTargetRoot;Initialize-WsmOutputWorkspace $wrongTargetRoot Target -Mode Directory | Out-Null
    $rejected=$false;try{Import-WsmDirectoryDelivery $delivery.SummaryPath $summaryHash $relocated $wrongTargetRoot | Out-Null}catch{$rejected=$true}
    Assert-DirectoryImport $rejected 'Wrong target fingerprint was accepted.'
    Assert-DirectoryImport (-not [IO.Directory]::Exists((Join-Path $wrongTargetRoot ('pairs\'+$pair))) -and -not [IO.Directory]::Exists((Join-Path $wrongTargetRoot 'workspace-control\directory-imports'))) 'Wrong-target rejection created a pair or incoming directory before target binding.'

    & $module {$script:fixtureFingerprint=('b'*64)}
    $wizardTargetRoot=New-DirectoryImportTargetRoot;Initialize-WsmOutputWorkspace $wizardTargetRoot Target -Mode Directory | Out-Null
    $wizardAnswers=@('3','2',$wizardTargetRoot,$delivery.SummaryPath,$summaryHash,$relocated,'','0')
    & $module {
        param([string[]]$Answers,[string]$Workspace)
        $script:WizardAnswerQueue=New-Object 'System.Collections.Generic.Queue[string]'
        foreach($answer in $Answers){$script:WizardAnswerQueue.Enqueue($answer)}
        function script:Read-Host([string]$Prompt){if($script:WizardAnswerQueue.Count -eq 0){throw 'Wizard fixture ran out of menu answers.'};$script:WizardAnswerQueue.Dequeue()}
        function script:Read-WsmWizardValue([string]$Label,[switch]$Optional){if($script:WizardAnswerQueue.Count -eq 0){throw 'Wizard fixture ran out of field answers.'};$value=$script:WizardAnswerQueue.Dequeue();if(-not $Optional -and [string]::IsNullOrWhiteSpace($value)){throw 'Wizard fixture supplied a blank required field.'};$value}
        Show-WsmMigrationWizard -Workspace $Workspace
    } $wizardAnswers $manager | Out-Null
    $wizardPairRoot=Join-Path $wizardTargetRoot ('pairs\'+$pair);$wizardPackages=@(Get-ChildItem -LiteralPath $wizardPairRoot -Directory -Recurse | Where-Object {$_.Name -eq 'packages'} | ForEach-Object {Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue | Where-Object Name -EQ ([Guid]$delivery.DeliveryId).ToString('N')})
    Assert-DirectoryImport ($wizardPackages.Count -eq 1 -and (Test-WsmMigrationPackage (Join-Path $wizardPackages[0].FullName 'manifest.json') $package.SHA256).Valid) 'Target wizard Directory step did not call the real validated directory importer.'

    Write-Output 'PASS: sealed full Directory delivery import validates pinned summary, exact relocated member set, target binding and copied package before atomic incoming seal; MAX_PATH and cancellation bounds, wrong-kind, tamper, extra, missing and wrong-target inputs fail closed; target wizard step 2 uses the real importer.'
}finally{
    $cleanup=[IO.Path]::GetFullPath($root);$expectedPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($cleanup.StartsWith($expectedPrefix,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($cleanup).StartsWith('wsm-di-',[StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($cleanup)){
        try{[IO.Directory]::Delete($cleanup,$true)}catch{Remove-Item -LiteralPath $cleanup -Recurse -Force -ErrorAction SilentlyContinue}
    }
    foreach($targetRootPath in $ownedTargetRoots){$targetFull=[IO.Path]::GetFullPath($targetRootPath);$volume=[IO.Path]::GetPathRoot($targetFull);if([IO.Path]::GetDirectoryName($targetFull).TrimEnd('\') -ieq $volume.TrimEnd('\') -and [IO.Path]::GetFileName($targetFull).StartsWith('i-',[StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($targetFull)){try{[IO.Directory]::Delete($targetFull,$true)}catch{Remove-Item -LiteralPath $targetFull -Recurse -Force -ErrorAction SilentlyContinue}}}
}
