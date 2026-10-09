#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\src\DeltaWizard.ps1')
$script:deltaMenuRoot=Join-Path ([IO.Path]::GetTempPath()) ('delta-menu-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($script:deltaMenuRoot)
$script:fixturePairId=[Guid]::NewGuid().ToString();$script:fixturePlanHash='d'*64;$script:fixtureCurrentManifestHash='b'*64
$script:deltaMenuZip=Join-Path $script:deltaMenuRoot 'fixture-delta.zip';$script:deltaMenuImportRoot=Join-Path $script:deltaMenuRoot 'imported'
$script:deltaMenuTransport=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.3.0';Kind='ArtifactDeltaTransport';PairId=$script:fixturePairId;PlanHash=$script:fixturePlanHash;BaseManifestHash=('a'*64);CurrentManifestHash=$script:fixtureCurrentManifestHash;SummaryHash=('e'*64);ChangesHash=('f'*64);Members=@();BlobBytes=0;CreatedUtc=[DateTime]::UtcNow.ToString('o');Mode='IsolatedPilot'}
$script:deltaMenuTransportJson=ConvertTo-Json -InputObject $script:deltaMenuTransport -Depth 12 -Compress
$script:deltaMenuTransportBytes=(New-Object Text.UTF8Encoding($false)).GetBytes($script:deltaMenuTransportJson)
Add-Type -AssemblyName System.IO.Compression
$zipStream=[IO.File]::Open($script:deltaMenuZip,'CreateNew','ReadWrite','None')
try{$zip=New-Object IO.Compression.ZipArchive($zipStream,[IO.Compression.ZipArchiveMode]::Create,$true);try{$entry=$zip.CreateEntry('transport.json');$entryStream=$entry.Open();try{$entryStream.Write($script:deltaMenuTransportBytes,0,$script:deltaMenuTransportBytes.Length)}finally{$entryStream.Dispose()}}finally{$zip.Dispose()}}finally{$zipStream.Dispose()}
$script:deltaMenuZipHash=(Get-FileHash -LiteralPath $script:deltaMenuZip -Algorithm SHA256).Hash.ToLowerInvariant()
$script:deltaMenuVolumePath=Join-Path $script:deltaMenuRoot 'fixture-volume-transport.json'
$script:deltaMenuVolume=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.3.0';Kind='ArtifactDeltaVolumeTransport';FormatVersion=1;PairId=$script:fixturePairId;PlanHash=$script:fixturePlanHash;CurrentManifestHash=$script:fixtureCurrentManifestHash}
$script:deltaMenuVolumeJson=ConvertTo-Json -InputObject $script:deltaMenuVolume -Depth 12 -Compress
$script:deltaMenuVolumeBytes=(New-Object Text.UTF8Encoding($false)).GetBytes($script:deltaMenuVolumeJson)
[IO.File]::WriteAllBytes($script:deltaMenuVolumePath,$script:deltaMenuVolumeBytes)
$script:deltaMenuVolumeHash=(Get-FileHash -LiteralPath $script:deltaMenuVolumePath -Algorithm SHA256).Hash.ToLowerInvariant()
$script:deltaMenuDirectoryPath=Join-Path $script:deltaMenuRoot 'fixture-directory-transport.json'
$script:deltaMenuDirectory=$script:deltaMenuVolume | Select-Object *
$script:deltaMenuDirectory.Kind='ArtifactDeltaDirectoryTransport'
$script:deltaMenuDirectoryJson=ConvertTo-Json -InputObject $script:deltaMenuDirectory -Depth 12 -Compress
$script:deltaMenuDirectoryBytes=(New-Object Text.UTF8Encoding($false)).GetBytes($script:deltaMenuDirectoryJson)
[IO.File]::WriteAllBytes($script:deltaMenuDirectoryPath,$script:deltaMenuDirectoryBytes)
$script:deltaMenuDirectoryHash=(Get-FileHash -LiteralPath $script:deltaMenuDirectoryPath -Algorithm SHA256).Hash.ToLowerInvariant()

function Assert-DeltaMenu([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-DeltaMenuEventOrder([string[]]$Expected){$actual=New-Object 'System.Collections.Generic.List[string]';foreach($event in $script:deltaMenuCalls.Events){if($event.Kind -eq 'Read' -and $event.Label -like '確認*'){[void]$actual.Add('Ack')}elseif($event.Kind -in @('Preview','Apply','Repair')){[void]$actual.Add([string]$event.Kind)}};if(($actual.ToArray() -join ',') -cne ($Expected -join ',')){throw ('Delta menu event order mismatch. Expected '+($Expected -join ',')+'; got '+($actual.ToArray() -join ','))}}
$script:deltaMenuInputs=New-Object 'System.Collections.Generic.Queue[string]'
function Read-WsmWizardValue([string]$Label,[switch]$Optional){if(-not $script:deltaMenuInputs.Count){throw (New-Object IO.EndOfStreamException('Fixture input exhausted at '+$Label))};$value=$script:deltaMenuInputs.Dequeue();[void]$script:deltaMenuCalls.Events.Add(@{Kind='Read';Label=$Label;Value=$value});if($value -ceq '0'){throw (New-Object OperationCanceledException('fixture return'))};if($value -ceq 'literal:0'){$value='0'};$value}
function Set-DeltaMenuInputs([string[]]$Values){$script:deltaMenuInputs.Clear();foreach($value in $Values){$script:deltaMenuInputs.Enqueue($value)}}

$script:deltaMenuCalls=@{Invoke=(New-Object 'System.Collections.Generic.List[object]');Tokens=(New-Object 'System.Collections.Generic.List[object]');Profile=(New-Object 'System.Collections.Generic.List[object]');Imports=(New-Object 'System.Collections.Generic.List[object]');Receipts=(New-Object 'System.Collections.Generic.List[object]');Events=(New-Object 'System.Collections.Generic.List[object]');OperationMenu=0}
function Assert-WsmNoReparse([string]$Path){if((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Fixture path is a reparse point.'}}
function Get-WsmDeltaFileHash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function ConvertFrom-WsmJson([string]$Text){ConvertFrom-Json -InputObject $Text}
function Assert-WsmEnvelope($Data,[string]$Kind){if($Data.Kind -cne $Kind){throw ('Fixture envelope kind mismatch: '+$Kind)}}
function Assert-WsmId([string]$Id){$parsed=[Guid]::Empty;if(-not [Guid]::TryParse($Id,[ref]$parsed)){throw 'Fixture id is invalid.'}}
function Get-WsmToolFingerprint {'fixture-tool-fingerprint'}
function Assert-WsmDeltaPlanBinding($Plan,[string]$ExpectedHash,$Manifest){if($Plan.PairId -cne $Manifest.PairId -or $Plan.ToolFingerprint -cne 'fixture-tool-fingerprint'){throw 'Fixture plan/manifest binding mismatch.'}}
function Read-WsmTrustedJson([string]$Path,[string]$ExpectedHash){if($Path -like '*manifest.json'){[pscustomobject]@{SchemaVersion=1;Kind='MigrationPackage';PairId=$script:fixturePairId;PlanHash=$script:fixturePlanHash;Generation=2}}else{[pscustomobject]@{SchemaVersion=1;Kind='MigrationPlan';PairId=$script:fixturePairId;ToolFingerprint='fixture-tool-fingerprint';Mode='IsolatedPilot';ScopeMode='FileScope'}}}
function New-WsmWizardCancellation($PairId,$PlanHash,$ManifestHash,$StateDirectory){$token=[pscustomobject]@{PairId=$PairId;PlanHash=$PlanHash;ManifestHash=$ManifestHash;StateDirectory=[IO.Path]::GetFullPath($StateDirectory)};$script:deltaMenuCalls.Tokens.Add($token);$token}
function New-WsmArtifactDeltaManifest {param($BaseManifestPath,$BaseManifestHash,$BasePlanPath,$BasePlanHash,$CurrentManifestPath,$CurrentManifestHash,$CurrentPlanPath,$CurrentPlanHash,$OutputPath,$SummaryPath,$OwnedItemIds)$script:deltaMenuCalls.New=@{BaseManifestPath=$BaseManifestPath;BaseManifestHash=$BaseManifestHash;BasePlanPath=$BasePlanPath;BasePlanHash=$BasePlanHash;CurrentManifestPath=$CurrentManifestPath;CurrentManifestHash=$CurrentManifestHash;CurrentPlanPath=$CurrentPlanPath;CurrentPlanHash=$CurrentPlanHash;OutputPath=$OutputPath;SummaryPath=$SummaryPath;OwnedItemIds=@($OwnedItemIds)};[pscustomobject]@{ChangesPath=$OutputPath;ChangesHash='change-hash';SummaryPath=$SummaryPath;SummaryHash='summary-hash';Valid=$true}}
function Test-WsmArtifactDeltaManifest {param($SummaryPath,$SummaryHash,$ChangesPath,$BaseManifestPath,$BaseManifestHash,$BasePlanPath,$BasePlanHash,$CurrentManifestPath,$CurrentManifestHash,$CurrentPlanPath,$CurrentPlanHash)$script:deltaMenuCalls.Test=@{SummaryPath=$SummaryPath;SummaryHash=$SummaryHash;ChangesPath=$ChangesPath;BaseManifestPath=$BaseManifestPath;BaseManifestHash=$BaseManifestHash;BasePlanPath=$BasePlanPath;BasePlanHash=$BasePlanHash;CurrentManifestPath=$CurrentManifestPath;CurrentManifestHash=$CurrentManifestHash;CurrentPlanPath=$CurrentPlanPath;CurrentPlanHash=$CurrentPlanHash};[pscustomobject]@{Valid=$true}}
function Export-WsmArtifactDeltaZip {param($BaseManifestPath,$BaseManifestHash,$BasePlanPath,$BasePlanHash,$CurrentManifestPath,$CurrentManifestHash,$CurrentPlanPath,$CurrentPlanHash,$SummaryPath,$SummaryHash,$ChangesPath,$OutputPath,$CancellationToken)$script:deltaMenuCalls.Export=@{BaseManifestPath=$BaseManifestPath;BaseManifestHash=$BaseManifestHash;BasePlanPath=$BasePlanPath;BasePlanHash=$BasePlanHash;CurrentManifestPath=$CurrentManifestPath;CurrentManifestHash=$CurrentManifestHash;CurrentPlanPath=$CurrentPlanPath;CurrentPlanHash=$CurrentPlanHash;SummaryPath=$SummaryPath;SummaryHash=$SummaryHash;ChangesPath=$ChangesPath;OutputPath=$OutputPath;CancellationToken=$CancellationToken};[pscustomobject]@{Path=$OutputPath;SHA256='zip-hash'}}
function Resolve-WsmOutputWorkspace {param($WorkRoot,$Role,$PairId,$PlanHash,$AttemptId)
    $mode=if($WorkRoot -eq $script:deltaMenuDirectoryWorkRoot){'Directory'}elseif($WorkRoot -eq $script:deltaMenuVolumeWorkRoot){'Zip'}else{'Zip'}
    [void]$script:deltaMenuCalls.Profile.Add(@{WorkRoot=$WorkRoot;Role=$Role;PairId=$PairId;PlanHash=$PlanHash;AttemptId=$AttemptId;Mode=$mode})
    if($Role -eq 'Target' -and -not $PSBoundParameters.ContainsKey('AttemptId')){
        return [pscustomobject]@{StateDirectory=(Join-Path $WorkRoot ('pairs\'+$PairId+'\state'));Profile=[pscustomobject]@{Mode=$mode}}
    }
    $attempt=[pscustomobject]@{Mode=$mode;VolumeBytes=1048576}
    [pscustomobject]@{AttemptProfile=$attempt;AttemptId=$(if($AttemptId){$AttemptId}else{'attempt-fixture'});PackagesDirectory=(Join-Path $WorkRoot ('pairs\'+$PairId+'\attempts\attempt-fixture\packages'));ScratchDirectory=(Join-Path $WorkRoot ('pairs\'+$PairId+'\attempts\attempt-fixture\scratch'));ReportsDirectory=(Join-Path $WorkRoot ('pairs\'+$PairId+'\attempts\attempt-fixture\reports'));TransportDirectory=(Join-Path $WorkRoot ('pairs\'+$PairId+'\attempts\attempt-fixture\transport'))}
}
function Import-WsmArtifactDeltaByProfile {param($OutputProfile,$TransportPath,$ExpectedHash,$OutputDirectory,$ScratchDirectory,$CancellationToken)
    [void]$script:deltaMenuCalls.Imports.Add(@{OutputProfile=$OutputProfile;TransportPath=$TransportPath;ExpectedHash=$ExpectedHash;OutputDirectory=$OutputDirectory;ScratchDirectory=$ScratchDirectory;CancellationToken=$CancellationToken})
    [void][IO.Directory]::CreateDirectory($OutputDirectory)
    $bytes=if($OutputProfile.Mode -eq 'Directory'){$script:deltaMenuDirectoryBytes}else{$script:deltaMenuVolumeBytes}
    [IO.File]::WriteAllBytes((Join-Path $OutputDirectory 'transport.json'),$bytes)
    [pscustomobject]@{Directory=$OutputDirectory;TransportHash=$ExpectedHash;BaseManifestHash='base-manifest-hash';CurrentManifestHash=$script:fixtureCurrentManifestHash;Generation=2;Valid=$true}
}
function Export-WsmImportedDeliveryReceipt {param($TransportPath,$ExpectedHash,$ManifestPath,$ExpectedManifestHash,$BaseManifestPath,$BaseManifestHash,$OperationKind,$ImportedDirectory,$OutputDirectory)
    $script:deltaMenuCalls.Receipts.Add(@{TransportPath=$TransportPath;ExpectedHash=$ExpectedHash;ManifestPath=$ManifestPath;ExpectedManifestHash=$ExpectedManifestHash;BaseManifestPath=$BaseManifestPath;BaseManifestHash=$BaseManifestHash;OperationKind=$OperationKind;ImportedDirectory=$ImportedDirectory;OutputDirectory=$OutputDirectory})
    [pscustomobject]@{ReceiptPath=$OutputDirectory}
}
function Show-WsmOperationMenu {$script:deltaMenuCalls.OperationMenu++}
function Invoke-WsmArtifactDeltaRestore {
    [CmdletBinding(SupportsShouldProcess)]param($TransportPath,$ExpectedTransportHash,$ImportedDirectory,$TargetStateDirectory,$GeneralHostEvidence,$CancellationToken)
    $isPreview=($PSBoundParameters.ContainsKey('WhatIf') -and [bool]$PSBoundParameters['WhatIf'])
    $script:deltaMenuCalls.Invoke.Add(@{TransportPath=$TransportPath;ExpectedTransportHash=$ExpectedTransportHash;ImportedDirectory=$ImportedDirectory;TargetStateDirectory=$TargetStateDirectory;GeneralHostEvidence=@($GeneralHostEvidence);WhatIf=$isPreview;CancellationToken=$CancellationToken})
    [void]$script:deltaMenuCalls.Events.Add(@{Kind=$(if($isPreview){'Preview'}else{'Apply'})})
    if($isPreview){return [pscustomobject]@{Preview=$true;PairId=$script:fixturePairId;Generation=2}}
    [pscustomobject]@{PairId=$script:fixturePairId;Generation=2;TransactionPath=$script:deltaMenuTransactionPath;DeltaPackageManifestPath='materialized-manifest.json';DeltaPackageManifestHash='materialized-manifest-hash';Mode='IsolatedPilot';ProductionVerified=$false}
}
function Repair-WsmArtifactDeltaRestore {param($TransportPath,$ExpectedTransportHash,$ImportedDirectory,$TargetStateDirectory,$GeneralHostEvidence,$CancellationToken)$script:deltaMenuCalls.Repair=@{TransportPath=$TransportPath;ExpectedTransportHash=$ExpectedTransportHash;ImportedDirectory=$ImportedDirectory;TargetStateDirectory=$TargetStateDirectory;GeneralHostEvidence=@($GeneralHostEvidence);CancellationToken=$CancellationToken};[void]$script:deltaMenuCalls.Events.Add(@{Kind='Repair'});[pscustomobject]@{PairId=$script:fixturePairId;Generation=2;TransactionPath=$script:deltaMenuTransactionPath;DeltaPackageManifestPath='repaired-manifest.json';DeltaPackageManifestHash='repaired-manifest-hash'}}
function Read-WsmJson([string]$Path){if([IO.File]::Exists($Path) -and [IO.Path]::GetExtension($Path) -ieq '.json'){try{return ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path))}catch{}};[pscustomobject]@{Operations=@([pscustomobject]@{Backup='fixture-baseline-backup'})}}
function Get-WsmFailureDetails($Failure){[pscustomobject]@{Category='Fixture';Hint=$Failure.Exception.Message}}

$sourceInputs=@(
    '1','base-manifest.json',('a'*64),'approved-plan.json',$script:fixturePlanHash,
    'current-manifest.json',$script:fixtureCurrentManifestHash,'approved-plan.json',$script:fixturePlanHash,
    'changes.jsonl','summary.json','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    '2','summary.json',('e'*64),'changes.jsonl',
    'base-manifest.json',('a'*64),'approved-plan.json',$script:fixturePlanHash,
    'current-manifest.json',$script:fixtureCurrentManifestHash,'approved-plan.json',$script:fixturePlanHash,
    '3','base-manifest.json',('a'*64),'approved-plan.json',$script:fixturePlanHash,
    'current-manifest.json',$script:fixtureCurrentManifestHash,'approved-plan.json',$script:fixturePlanHash,
    'summary.json',('e'*64),'changes.jsonl',(Join-Path $script:deltaMenuRoot 'export.zip'),'0')
Set-DeltaMenuInputs $sourceInputs
Show-WsmDeltaWizard -Role Source | Out-Null
Assert-DeltaMenu ($script:deltaMenuCalls.New.BaseManifestPath -ceq 'base-manifest.json' -and $script:deltaMenuCalls.New.BaseManifestHash -ceq ('a'*64) -and $script:deltaMenuCalls.New.BasePlanPath -ceq 'approved-plan.json' -and $script:deltaMenuCalls.New.BasePlanHash -ceq $script:fixturePlanHash) 'Manifest producer did not receive the trusted base manifest/plan inputs.'
Assert-DeltaMenu ($script:deltaMenuCalls.New.CurrentManifestPath -ceq 'current-manifest.json' -and $script:deltaMenuCalls.New.CurrentManifestHash -ceq $script:fixtureCurrentManifestHash -and $script:deltaMenuCalls.New.CurrentPlanPath -ceq 'approved-plan.json' -and $script:deltaMenuCalls.New.CurrentPlanHash -ceq $script:fixturePlanHash -and $script:deltaMenuCalls.New.OwnedItemIds[0] -ceq ('a'*64)) 'Manifest producer lost current generation or owned-scope inputs.'
Assert-DeltaMenu ($script:deltaMenuCalls.Test.SummaryHash -ceq ('e'*64) -and $script:deltaMenuCalls.Test.ChangesPath -ceq 'changes.jsonl' -and $script:deltaMenuCalls.Test.BaseManifestHash -ceq ('a'*64) -and $script:deltaMenuCalls.Test.CurrentManifestHash -ceq $script:fixtureCurrentManifestHash -and $script:deltaMenuCalls.Test.CurrentPlanHash -ceq $script:fixturePlanHash) 'Delta validator did not receive summary/change and both generation bindings.'
Assert-DeltaMenu ($script:deltaMenuCalls.Export.SummaryHash -ceq ('e'*64) -and $script:deltaMenuCalls.Export.ChangesPath -ceq 'changes.jsonl' -and $script:deltaMenuCalls.Export.OutputPath -ceq ([IO.Path]::GetFullPath((Join-Path $script:deltaMenuRoot 'export.zip'))) -and $script:deltaMenuCalls.Export.BasePlanHash -ceq $script:fixturePlanHash -and $script:deltaMenuCalls.Export.CurrentManifestHash -ceq $script:fixtureCurrentManifestHash) 'ZIP exporter did not receive the trusted delta inputs.'
Assert-DeltaMenu ($script:deltaMenuCalls.Export.CancellationToken.PairId -ceq $script:fixturePairId -and $script:deltaMenuCalls.Export.CancellationToken.PlanHash -ceq $script:fixturePlanHash -and $script:deltaMenuCalls.Export.CancellationToken.ManifestHash -ceq $script:fixtureCurrentManifestHash -and $script:deltaMenuCalls.Export.CancellationToken.StateDirectory -ceq $script:deltaMenuRoot) 'ZIP exporter cancellation token is not bound to current pair/plan/manifest/output parent.'
Assert-DeltaMenu ($script:deltaMenuInputs.Count -eq 0) 'Source menu left unconsumed fixture input.'

$script:deltaMenuTransactionPath=Join-Path $script:deltaMenuRoot 'transaction.json'
[IO.File]::WriteAllText($script:deltaMenuTransactionPath,'fixture transaction placeholder')
$script:deltaMenuVolumeWorkRoot=Join-Path $script:deltaMenuRoot 'volume-workroot'
$script:deltaMenuDirectoryWorkRoot=Join-Path $script:deltaMenuRoot 'directory-workroot'
$script:deltaMenuTargetWorkRoot=Join-Path $script:deltaMenuRoot 'target-workroot'
$script:deltaMenuImportedPath=Join-Path $script:deltaMenuTargetWorkRoot ('pairs\'+$script:fixturePairId+'\attempts\attempt-fixture\packages\imported')
[void][IO.Directory]::CreateDirectory((Join-Path $script:deltaMenuImportedPath 'current'))
[IO.File]::WriteAllBytes((Join-Path $script:deltaMenuImportedPath 'transport.json'),$script:deltaMenuVolumeBytes)
[IO.File]::WriteAllText((Join-Path $script:deltaMenuImportedPath 'current\manifest.json'),'fixture')
[IO.File]::WriteAllText((Join-Path $script:deltaMenuImportedPath 'current\plan.json'),'fixture')
try{
Set-DeltaMenuInputs @('1','0')
Show-WsmDeltaWizard -Role Target | Out-Null
Assert-DeltaMenu ($script:deltaMenuCalls.OperationMenu -eq 1) 'Legacy Target option 1 must redirect to the advanced operation menu.'
$script:deltaMenuCalls.Events.Clear()
Set-DeltaMenuInputs @(
    '4',$script:deltaMenuVolumePath,$script:deltaMenuVolumeHash,$script:deltaMenuVolumeWorkRoot,'',
    '5',$script:deltaMenuDirectoryPath,$script:deltaMenuDirectoryHash,$script:deltaMenuDirectoryWorkRoot,'',
    '2',$script:deltaMenuVolumePath,$script:deltaMenuVolumeHash,$script:deltaMenuTargetWorkRoot,$script:deltaMenuImportedPath,('APPLY-DELTA '+$script:fixturePairId),
    '3',$script:deltaMenuVolumePath,$script:deltaMenuVolumeHash,$script:deltaMenuTargetWorkRoot,$script:deltaMenuImportedPath,('REPAIR-DELTA '+$script:fixturePairId),
    '0')
Show-WsmDeltaWizard -Role Target | Out-Null
Assert-DeltaMenu ($script:deltaMenuCalls.Imports.Count -eq 2 -and $script:deltaMenuCalls.Imports[0].TransportPath -ceq $script:deltaMenuVolumePath -and $script:deltaMenuCalls.Imports[0].ExpectedHash -ceq $script:deltaMenuVolumeHash -and $script:deltaMenuCalls.Imports[0].OutputProfile.Mode -ceq 'Zip' -and $script:deltaMenuCalls.Imports[0].ScratchDirectory -like '*scratch' -and $script:deltaMenuCalls.Imports[1].TransportPath -ceq $script:deltaMenuDirectoryPath -and $script:deltaMenuCalls.Imports[1].ExpectedHash -ceq $script:deltaMenuDirectoryHash -and $script:deltaMenuCalls.Imports[1].OutputProfile.Mode -ceq 'Directory') 'Modern profile-bound delta imports did not receive each trusted transport, enrolled profile and scratch path.'
Assert-DeltaMenu ($script:deltaMenuCalls.Imports[0].CancellationToken.PairId -ceq $script:fixturePairId -and $script:deltaMenuCalls.Imports[0].CancellationToken.PlanHash -ceq $script:fixturePlanHash -and $script:deltaMenuCalls.Imports[0].CancellationToken.ManifestHash -ceq $script:fixtureCurrentManifestHash -and $script:deltaMenuCalls.Imports[0].CancellationToken.StateDirectory -ceq $script:deltaMenuCalls.Imports[0].OutputDirectory -and $script:deltaMenuCalls.Imports[1].CancellationToken.StateDirectory -ceq $script:deltaMenuCalls.Imports[1].OutputDirectory) 'Profile-bound importer cancellation tokens are not bound to their transport identity/output directories.'
Assert-DeltaMenu ($script:deltaMenuCalls.Receipts.Count -eq 2 -and $script:deltaMenuCalls.Receipts[0].OperationKind -ceq 'Delta' -and $script:deltaMenuCalls.Receipts[1].OperationKind -ceq 'Delta') 'Both modern profile-bound imports must automatically export native delivery receipts.'
Assert-DeltaMenu ($script:deltaMenuCalls.Receipts[0].TransportPath -ceq $script:deltaMenuVolumePath -and $script:deltaMenuCalls.Receipts[0].ImportedDirectory -ceq $script:deltaMenuCalls.Imports[0].OutputDirectory -and $script:deltaMenuCalls.Receipts[0].ExpectedHash -ceq $script:deltaMenuVolumeHash -and $script:deltaMenuCalls.Receipts[1].TransportPath -ceq $script:deltaMenuDirectoryPath -and $script:deltaMenuCalls.Receipts[1].ImportedDirectory -ceq $script:deltaMenuCalls.Imports[1].OutputDirectory -and $script:deltaMenuCalls.Receipts[1].ExpectedHash -ceq $script:deltaMenuDirectoryHash) 'Automatic import receipts lost the exact trusted transport/import bindings.'
Assert-DeltaMenu ($script:deltaMenuCalls.Profile.Count -eq 4 -and $script:deltaMenuCalls.Profile[0].Role -ceq 'Target' -and $script:deltaMenuCalls.Profile[0].Mode -ceq 'Zip' -and $script:deltaMenuCalls.Profile[1].Mode -ceq 'Directory') 'Modern import actions did not resolve the matching target OutputProfile mode.'
Assert-DeltaMenu ($script:deltaMenuCalls.Invoke.Count -eq 3 -and $script:deltaMenuCalls.Invoke[0].WhatIf -and -not $script:deltaMenuCalls.Invoke[1].WhatIf -and $script:deltaMenuCalls.Invoke[2].WhatIf) ('Target apply/repair did not preview before acknowledgement and actual apply: '+($script:deltaMenuCalls.Invoke | ConvertTo-Json -Compress))
foreach($call in $script:deltaMenuCalls.Invoke){Assert-DeltaMenu ($call.TransportPath -ceq $script:deltaMenuVolumePath -and $call.ExpectedTransportHash -ceq $script:deltaMenuVolumeHash -and $call.ImportedDirectory -ceq $script:deltaMenuImportedPath -and $call.TargetStateDirectory -like '*\state') 'Target preview/apply lost transport, imported directory, or profile-resolved local state binding.'}
Assert-DeltaMenu ($script:deltaMenuCalls.Invoke[0].CancellationToken -eq $null -and $script:deltaMenuCalls.Invoke[2].CancellationToken -eq $null) 'Preview must remain read-only and must not receive a cancellation marker token.'
Assert-DeltaMenu ($script:deltaMenuCalls.Invoke[1].CancellationToken.PairId -ceq $script:fixturePairId -and $script:deltaMenuCalls.Invoke[1].CancellationToken.PlanHash -ceq $script:fixturePlanHash -and $script:deltaMenuCalls.Invoke[1].CancellationToken.ManifestHash -ceq $script:fixtureCurrentManifestHash -and $script:deltaMenuCalls.Invoke[1].CancellationToken.StateDirectory -ceq $script:deltaMenuCalls.Invoke[1].TargetStateDirectory) 'Apply cancellation token is not bound to previewed pair/plan/current manifest/profile state directory.'
Assert-DeltaMenu ($script:deltaMenuCalls.Repair.TransportPath -ceq $script:deltaMenuVolumePath -and $script:deltaMenuCalls.Repair.ExpectedTransportHash -ceq $script:deltaMenuVolumeHash -and $script:deltaMenuCalls.Repair.ImportedDirectory -ceq $script:deltaMenuImportedPath -and $script:deltaMenuCalls.Repair.TargetStateDirectory -like '*\state') 'Delta repair did not receive the exact imported transport and resolved target state.'
Assert-DeltaMenu ($script:deltaMenuCalls.Repair.CancellationToken.PairId -ceq $script:fixturePairId -and $script:deltaMenuCalls.Repair.CancellationToken.PlanHash -ceq $script:fixturePlanHash -and $script:deltaMenuCalls.Repair.CancellationToken.ManifestHash -ceq $script:fixtureCurrentManifestHash -and $script:deltaMenuCalls.Repair.CancellationToken.StateDirectory -ceq $script:deltaMenuCalls.Repair.TargetStateDirectory) 'Repair cancellation token is not bound to previewed pair/plan/current manifest/profile state directory.'
Assert-DeltaMenu ($script:deltaMenuCalls.Tokens.Count -eq 5) 'Cancellation controls must be created only for Source export, both profile-bound imports, acknowledged Apply and acknowledged Repair; previews and the legacy redirect must not create one.'
Assert-DeltaMenuEventOrder @('Preview','Ack','Apply','Preview','Ack','Repair')
Assert-DeltaMenu ($script:deltaMenuInputs.Count -eq 0) 'Target menu left unconsumed fixture input.'

$tokenCountBeforeRejectedAck=$script:deltaMenuCalls.Tokens.Count;$script:deltaMenuCalls.Invoke.Clear();$script:deltaMenuCalls.Events.Clear()
Set-DeltaMenuInputs @('2',$script:deltaMenuVolumePath,$script:deltaMenuVolumeHash,$script:deltaMenuTargetWorkRoot,$script:deltaMenuImportedPath,'WRONG-ACK','0')
Show-WsmDeltaWizard -Role Target | Out-Null
Assert-DeltaMenu ($script:deltaMenuCalls.Invoke.Count -eq 1 -and $script:deltaMenuCalls.Invoke[0].WhatIf -and $script:deltaMenuCalls.Tokens.Count -eq $tokenCountBeforeRejectedAck) 'Apply without its exact pair acknowledgement must remain preview-only and must not create a cancellation token.'
Assert-DeltaMenuEventOrder @('Preview','Ack')
$script:deltaMenuCalls.Invoke.Clear();$script:deltaMenuCalls.Events.Clear();$script:deltaMenuCalls.Repair=$null
Set-DeltaMenuInputs @('3',$script:deltaMenuVolumePath,$script:deltaMenuVolumeHash,$script:deltaMenuTargetWorkRoot,$script:deltaMenuImportedPath,'WRONG-ACK','0')
Show-WsmDeltaWizard -Role Target | Out-Null
Assert-DeltaMenu ($script:deltaMenuCalls.Invoke.Count -eq 1 -and $script:deltaMenuCalls.Invoke[0].WhatIf -and $null -eq $script:deltaMenuCalls.Repair -and $script:deltaMenuCalls.Tokens.Count -eq $tokenCountBeforeRejectedAck) 'Repair without its exact pair acknowledgement must remain preview-only and must not create a cancellation token.'
Assert-DeltaMenuEventOrder @('Preview','Ack')
}finally{if([IO.Directory]::Exists($script:deltaMenuRoot)){Remove-Item -LiteralPath $script:deltaMenuRoot -Recurse -Force}}
Set-DeltaMenuInputs @()
$eofPropagated=$false
try{Show-WsmDeltaWizard -Role Source | Out-Null}catch [IO.EndOfStreamException]{$eofPropagated=$true}
Assert-DeltaMenu $eofPropagated 'Console EOF must escape the delta submenu to the caller.'
Write-Host 'PASS: Delta menu covers legacy redirection, profile-bound import/receipt, preview-before-ack/apply/repair, rejected-ack token guards, and trusted pair/plan/current-manifest/state-bound cancellation tokens.'
