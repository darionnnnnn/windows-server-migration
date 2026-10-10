#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-native-stage-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try { & $module {
 param($root)
 $script:checks=0
 function Check([bool]$Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
 $id=[Guid]::NewGuid().ToString();$file=Join-Path $root 'owned.ini';[IO.File]::WriteAllText($file,'approved bytes')
 # Canonicalize the ambient ACL only through the production writer. Capture the expected
 # ownership baseline after two real write/readback cycles so the fixture tests a stable,
 # verified native descriptor rather than a pre-normalization temp-directory descriptor.
 $seedMetadata=Get-WsmFileMetadata $file DaclOwner;Set-WsmFileMetadata $file $seedMetadata @{};$metadata=Get-WsmFileMetadata $file DaclOwner;$metadataHash=Get-WsmAssistiveMetadataHash $metadata;Set-WsmFileMetadata $file $metadata @{};$initialNativeMetadata=Get-WsmFileMetadata $file DaclOwner;$initialNativeMetadataHash=Get-WsmAssistiveMetadataHash $initialNativeMetadata;$hash=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
 Check ($initialNativeMetadataHash -ceq $metadataHash) ('Production metadata writer did not preserve its first canonical native readback. expected='+$metadataHash+' observed='+$initialNativeMetadataHash+' expectedSddlHash='+(Get-WsmHashText ([string]$metadata.Sddl))+' observedSddlHash='+(Get-WsmHashText ([string]$initialNativeMetadata.Sddl))+' expectedAttributes='+$metadata.Attributes+' observedAttributes='+$initialNativeMetadata.Attributes+' expectedCreation='+$metadata.CreationUtc+' observedCreation='+$initialNativeMetadata.CreationUtc+' expectedLastWrite='+$metadata.LastWriteUtc+' observedLastWrite='+$initialNativeMetadata.LastWriteUtc)
 $item=[pscustomobject]@{ItemId=$id;MigrationSpec=[pscustomobject]@{Adapter='FileScope';TransferChannel='NonC';TargetPath=$file;SourcePath='C:\source\owned.ini';Metadata='DaclOwner'}}
 $package=[pscustomobject]@{Root=$root;Manifest=[pscustomobject]@{Generation=3;ArtifactsHash=('a'*64)}}
 $row=[pscustomobject]@{ItemId=$id;EntryId=('b'*64);RelativePath='';EntryType='File';EffectivePath=$file;Status='Applied';ObservedHash=$hash;SourceHash=$hash;MetadataHash=$metadataHash;ExistingTargetPath='';ExistingTargetHash='';OriginalPath='D:\source\owned.ini';PreservedPath=$file;Reason='';Generation=3}
 $state=[pscustomobject]@{Items=@();AssistiveFileResults=@($row)};$items=@{};$items[$id]=$item
 $actual=@(Get-WsmAssistiveStageFileResultRows $package $state @($id) $items)
 Check ($actual.Count -eq 1 -and $actual[0].EffectivePath -ceq $file -and $actual[0].Status -ceq 'Applied') 'Current native NonC readback lost its verified effective path.'
 $link=Join-Path $root 'external-hardlink.ini';New-Item -ItemType HardLink -Path $link -Target $file | Out-Null
 $actual=@(Get-WsmAssistiveStageFileResultRows $package $state @($id) $items)
 Check ($actual[0].Status -ceq 'Deferred' -and -not $actual[0].EffectivePath -and [IO.File]::ReadAllText($link) -ceq 'approved bytes') 'A new hardlink escaped NonC topology readback or altered external content.'
 [IO.File]::Delete($link);Set-WsmFileMetadata $file $metadata @{}
 [IO.File]::SetLastWriteTimeUtc($file,[DateTime]::UtcNow.AddMinutes(-10));$actual=@(Get-WsmAssistiveStageFileResultRows $package $state @($id) $items)
 Check ($actual[0].Status -ceq 'Deferred' -and -not $actual[0].EffectivePath) 'Metadata drift retained a falsely usable NonC path.'
 Set-WsmFileMetadata $file $metadata @{};[IO.File]::WriteAllText($file,'operator bytes');$actual=@(Get-WsmAssistiveStageFileResultRows $package $state @($id) $items)
 Check ($actual[0].Status -ceq 'Deferred' -and -not $actual[0].EffectivePath -and [IO.File]::ReadAllText($file) -ceq 'operator bytes') 'NonC byte drift was hidden or modified by report projection.'
 [IO.File]::WriteAllText($file,'approved bytes');Set-WsmFileMetadata $file $metadata @{};$row.Generation=2;$actual=@(Get-WsmAssistiveStageFileResultRows $package $state @($id) $items)
 Check ($actual[0].Status -ceq 'Deferred' -and -not $actual[0].EffectivePath) 'An old NonC generation was promoted to the current generation.'
 $row.Generation=3;$row.PSObject.Properties.Remove('MetadataHash');$actual=@(Get-WsmAssistiveStageFileResultRows $package $state @($id) $items)
 Check ($actual[0].Status -ceq 'Deferred' -and -not $actual[0].EffectivePath) 'Missing NonC metadata baseline was accepted.'
 $item.MigrationSpec.TransferChannel='C';$script:stageArtifact=[pscustomobject]@{ItemId=$id;RelativePath='';Directory=$false;Data=[pscustomobject]@{Hash=$hash}}
 function Read-WsmArtifactLines { @($script:stageArtifact) } # Only artifact stream isolated; native hash and ACL/time readback are real.
 $state.Items=@([pscustomobject]@{ItemId=$id;FileResults=@([pscustomobject]@{RelativePath='';Status='Applied';Reason=''});OwnedFiles=@([pscustomobject]@{RelativePath='';Generation=3;SHA256=$hash;MetadataHash=$metadataHash});OwnedDirectories=@()})
 $actual=@(Get-WsmAssistiveStageFileResultRows $package $state @($id) $items)
 $currentCMetadata=Get-WsmFileMetadata $file DaclOwner;$currentCMetadataHash=Get-WsmAssistiveMetadataHash $currentCMetadata;$currentCBytes=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant();$cTopologyError='';try{Assert-WsmAssistiveFileTopology $file}catch{$cTopologyError=$_.Exception.Message}
 Check ($actual[0].Status -ceq 'Applied' -and $actual[0].EffectivePath -ceq $file) ('Current C ownership did not produce a verified native path. row='+($actual[0]|ConvertTo-Json -Depth 8 -Compress)+' expectedMetadataHash='+$metadataHash+' nativeMetadataHash='+$currentCMetadataHash+' ownedMetadataHash='+$state.Items[0].OwnedFiles[0].MetadataHash+' nativeBytes='+$currentCBytes+' expectedBytes='+$hash+' topologyError='+$cTopologyError+' metadata='+($currentCMetadata|ConvertTo-Json -Compress))
 [IO.File]::SetLastWriteTimeUtc($file,[DateTime]::UtcNow.AddMinutes(-5));$actual=@(Get-WsmAssistiveStageFileResultRows $package $state @($id) $items)
 Check ($actual[0].Status -ceq 'Deferred' -and -not $actual[0].EffectivePath) 'C metadata drift retained a falsely usable path.'
 Set-Content -LiteralPath $file -Stream 'manual-proof' -Value 'preserve this stream' -NoNewline;$actual=@(Get-WsmAssistiveStageFileResultRows $package $state @($id) $items)
 Check ($actual[0].Status -ceq 'Deferred' -and -not $actual[0].EffectivePath -and $actual[0].ExistingTargetPath -ceq $file -and $actual[0].PreservedPath -ceq $file -and $actual[0].OriginalPath -ceq 'C:\source\owned.ini') 'C topology refusal omitted the exact target/manual path or confused it with the source path.'
 Check ((Get-Content -LiteralPath $file -Stream 'manual-proof' -Raw) -ceq 'preserve this stream') 'C reporting changed a refused target stream.'
 Write-Host ('PASS: '+$script:checks+' native C/NonC stage readback checks; only C artifact enumeration is isolated.')
} $root } finally {Remove-Item -LiteralPath $root -Recurse -Force}
