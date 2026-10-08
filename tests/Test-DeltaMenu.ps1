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

function Assert-DeltaMenu([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
$script:deltaMenuInputs=New-Object 'System.Collections.Generic.Queue[string]'
function Read-WsmWizardValue([string]$Label,[switch]$Optional){if(-not $script:deltaMenuInputs.Count){throw (New-Object IO.EndOfStreamException('Fixture input exhausted at '+$Label))};$value=$script:deltaMenuInputs.Dequeue();if($value -ceq '0'){throw (New-Object OperationCanceledException('fixture return'))};if($value -ceq 'literal:0'){$value='0'};$value}
function Set-DeltaMenuInputs([string[]]$Values){$script:deltaMenuInputs.Clear();foreach($value in $Values){$script:deltaMenuInputs.Enqueue($value)}}

$script:deltaMenuCalls=@{Invoke=(New-Object 'System.Collections.Generic.List[object]');Tokens=(New-Object 'System.Collections.Generic.List[object]')}
function Assert-WsmNoReparse([string]$Path){if((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Fixture path is a reparse point.'}}
function Get-WsmDeltaFileHash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function ConvertFrom-WsmJson([string]$Text){ConvertFrom-Json -InputObject $Text}
function Assert-WsmEnvelope($Data,[string]$Kind){if($Data.Kind -cne $Kind){throw ('Fixture envelope kind mismatch: '+$Kind)}}
function Assert-WsmId([string]$Id){$parsed=[Guid]::Empty;if(-not [Guid]::TryParse($Id,[ref]$parsed)){throw 'Fixture id is invalid.'}}
function Get-WsmToolFingerprint {'fixture-tool-fingerprint'}
function Assert-WsmDeltaPlanBinding($Plan,[string]$ExpectedHash,$Manifest){if($Plan.PairId -cne $Manifest.PairId -or $Plan.ToolFingerprint -cne 'fixture-tool-fingerprint'){throw 'Fixture plan/manifest binding mismatch.'}}
function Read-WsmTrustedJson([string]$Path,[string]$ExpectedHash){if($Path -like '*current-manifest*'){[pscustomobject]@{SchemaVersion=1;Kind='MigrationPackage';PairId=$script:fixturePairId;PlanHash=$script:fixturePlanHash;Generation=2}}else{[pscustomobject]@{SchemaVersion=1;Kind='MigrationPlan';PairId=$script:fixturePairId;ToolFingerprint='fixture-tool-fingerprint';Mode='IsolatedPilot'}}}
function New-WsmWizardCancellation($PairId,$PlanHash,$ManifestHash,$StateDirectory){$token=[pscustomobject]@{PairId=$PairId;PlanHash=$PlanHash;ManifestHash=$ManifestHash;StateDirectory=[IO.Path]::GetFullPath($StateDirectory)};$script:deltaMenuCalls.Tokens.Add($token);$token}
function New-WsmArtifactDeltaManifest {param($BaseManifestPath,$BaseManifestHash,$BasePlanPath,$BasePlanHash,$CurrentManifestPath,$CurrentManifestHash,$CurrentPlanPath,$CurrentPlanHash,$OutputPath,$SummaryPath,$OwnedItemIds)$script:deltaMenuCalls.New=@{BaseManifestPath=$BaseManifestPath;BaseManifestHash=$BaseManifestHash;BasePlanPath=$BasePlanPath;BasePlanHash=$BasePlanHash;CurrentManifestPath=$CurrentManifestPath;CurrentManifestHash=$CurrentManifestHash;CurrentPlanPath=$CurrentPlanPath;CurrentPlanHash=$CurrentPlanHash;OutputPath=$OutputPath;SummaryPath=$SummaryPath;OwnedItemIds=@($OwnedItemIds)};[pscustomobject]@{ChangesPath=$OutputPath;ChangesHash='change-hash';SummaryPath=$SummaryPath;SummaryHash='summary-hash';Valid=$true}}
function Test-WsmArtifactDeltaManifest {param($SummaryPath,$SummaryHash,$ChangesPath,$BaseManifestPath,$BaseManifestHash,$BasePlanPath,$BasePlanHash,$CurrentManifestPath,$CurrentManifestHash,$CurrentPlanPath,$CurrentPlanHash)$script:deltaMenuCalls.Test=@{SummaryPath=$SummaryPath;SummaryHash=$SummaryHash;ChangesPath=$ChangesPath;BaseManifestPath=$BaseManifestPath;BaseManifestHash=$BaseManifestHash;BasePlanPath=$BasePlanPath;BasePlanHash=$BasePlanHash;CurrentManifestPath=$CurrentManifestPath;CurrentManifestHash=$CurrentManifestHash;CurrentPlanPath=$CurrentPlanPath;CurrentPlanHash=$CurrentPlanHash};[pscustomobject]@{Valid=$true}}
function Export-WsmArtifactDeltaZip {param($BaseManifestPath,$BaseManifestHash,$BasePlanPath,$BasePlanHash,$CurrentManifestPath,$CurrentManifestHash,$CurrentPlanPath,$CurrentPlanHash,$SummaryPath,$SummaryHash,$ChangesPath,$OutputPath,$CancellationToken)$script:deltaMenuCalls.Export=@{BaseManifestPath=$BaseManifestPath;BaseManifestHash=$BaseManifestHash;BasePlanPath=$BasePlanPath;BasePlanHash=$BasePlanHash;CurrentManifestPath=$CurrentManifestPath;CurrentManifestHash=$CurrentManifestHash;CurrentPlanPath=$CurrentPlanPath;CurrentPlanHash=$CurrentPlanHash;SummaryPath=$SummaryPath;SummaryHash=$SummaryHash;ChangesPath=$ChangesPath;OutputPath=$OutputPath;CancellationToken=$CancellationToken};[pscustomobject]@{Path=$OutputPath;SHA256='zip-hash'}}
function Import-WsmArtifactDeltaZip {param($TransportPath,$ExpectedHash,$OutputDirectory,$CancellationToken)$script:deltaMenuCalls.Import=@{TransportPath=$TransportPath;ExpectedHash=$ExpectedHash;OutputDirectory=$OutputDirectory;CancellationToken=$CancellationToken};[void][IO.Directory]::CreateDirectory($OutputDirectory);[IO.File]::WriteAllBytes((Join-Path $OutputDirectory 'transport.json'),$script:deltaMenuTransportBytes);[pscustomobject]@{Directory=$OutputDirectory;TransportHash=$ExpectedHash;BaseManifestHash='base-manifest-hash';CurrentManifestHash=$script:fixtureCurrentManifestHash;Generation=2;Valid=$true}}
function Invoke-WsmArtifactDeltaRestore {
    [CmdletBinding(SupportsShouldProcess)]param($TransportPath,$ExpectedTransportHash,$ImportedDirectory,$TargetStateDirectory,$CancellationToken)
    $isPreview=($PSBoundParameters.ContainsKey('WhatIf') -and [bool]$PSBoundParameters['WhatIf'])
    $script:deltaMenuCalls.Invoke.Add(@{TransportPath=$TransportPath;ExpectedTransportHash=$ExpectedTransportHash;ImportedDirectory=$ImportedDirectory;TargetStateDirectory=$TargetStateDirectory;WhatIf=$isPreview;CancellationToken=$CancellationToken})
    if($isPreview){return [pscustomobject]@{Preview=$true;PairId=$script:fixturePairId;Generation=2}}
    [pscustomobject]@{PairId=$script:fixturePairId;Generation=2;TransactionPath=$script:deltaMenuTransactionPath;DeltaPackageManifestPath='materialized-manifest.json';DeltaPackageManifestHash='materialized-manifest-hash';Mode='IsolatedPilot';ProductionVerified=$false}
}
function Repair-WsmArtifactDeltaRestore {param($TransportPath,$ExpectedTransportHash,$ImportedDirectory,$TargetStateDirectory,$CancellationToken)$script:deltaMenuCalls.Repair=@{TransportPath=$TransportPath;ExpectedTransportHash=$ExpectedTransportHash;ImportedDirectory=$ImportedDirectory;TargetStateDirectory=$TargetStateDirectory;CancellationToken=$CancellationToken};[pscustomobject]@{PairId=$script:fixturePairId;Generation=2;TransactionPath=$script:deltaMenuTransactionPath;DeltaPackageManifestPath='repaired-manifest.json';DeltaPackageManifestHash='repaired-manifest-hash'}}
function Read-WsmJson([string]$Path){[pscustomobject]@{Operations=@([pscustomobject]@{Backup='fixture-baseline-backup'})}}
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
try{
Set-DeltaMenuInputs @('1',$script:deltaMenuZip,$script:deltaMenuZipHash,$script:deltaMenuImportRoot,'2',$script:deltaMenuZip,$script:deltaMenuZipHash,$script:deltaMenuImportRoot,$script:deltaMenuRoot,('APPLY-DELTA '+$script:fixturePairId),'3',$script:deltaMenuZip,$script:deltaMenuZipHash,$script:deltaMenuImportRoot,$script:deltaMenuRoot,('REPAIR-DELTA '+$script:fixturePairId),'0')
Show-WsmDeltaWizard -Role Target | Out-Null
Assert-DeltaMenu ($script:deltaMenuCalls.Import.TransportPath -ceq $script:deltaMenuZip -and $script:deltaMenuCalls.Import.ExpectedHash -ceq $script:deltaMenuZipHash -and $script:deltaMenuCalls.Import.OutputDirectory -ceq $script:deltaMenuImportRoot) 'Delta ZIP importer did not receive the trusted archive path/hash and output directory.'
Assert-DeltaMenu ($script:deltaMenuCalls.Import.CancellationToken.PairId -ceq $script:fixturePairId -and $script:deltaMenuCalls.Import.CancellationToken.PlanHash -ceq $script:fixturePlanHash -and $script:deltaMenuCalls.Import.CancellationToken.ManifestHash -ceq $script:fixtureCurrentManifestHash -and $script:deltaMenuCalls.Import.CancellationToken.StateDirectory -ceq $script:deltaMenuImportRoot) 'ZIP importer cancellation token is not bound to archive pair/plan/current manifest/output directory.'
Assert-DeltaMenu ($script:deltaMenuCalls.Invoke.Count -eq 3 -and $script:deltaMenuCalls.Invoke[0].WhatIf -and -not $script:deltaMenuCalls.Invoke[1].WhatIf -and $script:deltaMenuCalls.Invoke[2].WhatIf) ('Target apply/repair did not preview before the actual apply: '+($script:deltaMenuCalls.Invoke | ConvertTo-Json -Compress))
foreach($call in $script:deltaMenuCalls.Invoke){Assert-DeltaMenu ($call.TransportPath -ceq $script:deltaMenuZip -and $call.ExpectedTransportHash -ceq $script:deltaMenuZipHash -and $call.ImportedDirectory -ceq $script:deltaMenuImportRoot -and $call.TargetStateDirectory -ceq $script:deltaMenuRoot) 'Target preview/apply lost transport, imported directory, or local state binding.'}
Assert-DeltaMenu ($script:deltaMenuCalls.Invoke[0].CancellationToken -eq $null -and $script:deltaMenuCalls.Invoke[2].CancellationToken -eq $null) 'Preview must remain read-only and must not receive a cancellation marker token.'
Assert-DeltaMenu ($script:deltaMenuCalls.Invoke[1].CancellationToken.PairId -ceq $script:fixturePairId -and $script:deltaMenuCalls.Invoke[1].CancellationToken.PlanHash -ceq $script:fixturePlanHash -and $script:deltaMenuCalls.Invoke[1].CancellationToken.ManifestHash -ceq $script:fixtureCurrentManifestHash -and $script:deltaMenuCalls.Invoke[1].CancellationToken.StateDirectory -ceq $script:deltaMenuRoot) 'Apply cancellation token is not bound to previewed pair/plan/current manifest/state directory.'
Assert-DeltaMenu ($script:deltaMenuCalls.Repair.TransportPath -ceq $script:deltaMenuZip -and $script:deltaMenuCalls.Repair.ExpectedTransportHash -ceq $script:deltaMenuZipHash -and $script:deltaMenuCalls.Repair.ImportedDirectory -ceq $script:deltaMenuImportRoot -and $script:deltaMenuCalls.Repair.TargetStateDirectory -ceq $script:deltaMenuRoot) 'Delta repair did not receive the exact imported transport and target state.'
Assert-DeltaMenu ($script:deltaMenuCalls.Repair.CancellationToken.PairId -ceq $script:fixturePairId -and $script:deltaMenuCalls.Repair.CancellationToken.PlanHash -ceq $script:fixturePlanHash -and $script:deltaMenuCalls.Repair.CancellationToken.ManifestHash -ceq $script:fixtureCurrentManifestHash -and $script:deltaMenuCalls.Repair.CancellationToken.StateDirectory -ceq $script:deltaMenuRoot) 'Repair cancellation token is not bound to previewed pair/plan/current manifest/state directory.'
Assert-DeltaMenu ($script:deltaMenuCalls.Tokens.Count -eq 4) 'Cancellation controls must be created only for Export, Import, acknowledged Apply and acknowledged Repair; preview must not create one.'
Assert-DeltaMenu ($script:deltaMenuInputs.Count -eq 0) 'Target menu left unconsumed fixture input.'
}finally{if([IO.Directory]::Exists($script:deltaMenuRoot)){Remove-Item -LiteralPath $script:deltaMenuRoot -Recurse -Force}}
Set-DeltaMenuInputs @()
$eofPropagated=$false
try{Show-WsmDeltaWizard -Role Source | Out-Null}catch [IO.EndOfStreamException]{$eofPropagated=$true}
Assert-DeltaMenu $eofPropagated 'Console EOF must escape the delta submenu to the caller.'
Write-Host 'PASS: Delta menu passes trusted hashes and pair/plan/current-manifest/state-bound cancellation tokens through the four heavy consumers; preview remains token-free.'
