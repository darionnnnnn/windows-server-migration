#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$helper=Join-Path $PSScriptRoot '..\src\AssistiveFiles.ps1'

$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-exact-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try{
    & $module {
        param($root,$helper)
        . $helper
        function Check($ok,$message){if(-not $ok){throw $message};$script:checks++}
        function Reject($action,$message){$rejected=$false;try{& $action | Out-Null}catch{$rejected=$true};Check $rejected $message}
        $script:checks=0
        $source=Join-Path $root 'source';$output=Join-Path $root 'output'
        [void][IO.Directory]::CreateDirectory((Join-Path $source 'settings'))
        [void][IO.Directory]::CreateDirectory($output)
        $config=Join-Path $source 'settings\appsettings.json';[IO.File]::WriteAllText($config,'{"business":"fixture"}')
        [IO.File]::WriteAllText((Join-Path $source 'installer.exe'),'not business data')
        [IO.File]::WriteAllText((Join-Path $source 'settings\secret.txt'),'not selected')
        $spec=[pscustomobject]@{Adapter='FileScope';SourcePath=$source;TargetPath='D:\RestoredSettings';ExcludedRelativePaths=@();Consistency='OwnerFreeze';Metadata='DaclOwner';ConflictPolicy='Block';Owner='fixture';Evidence='fixture approval';TransferChannel='C';ContentSelection='ExactFiles';ConfigFiles=@([pscustomobject]@{RelativePath='settings\appsettings.json';SHA256=(Get-FileHash $config).Hash.ToLowerInvariant();Owner='fixture';Evidence='exact file approval'})}
        $entries=@(Get-WsmScopeEntries $spec $output)
        Check ($entries.Count -eq 3) 'Exact whitelist did not capture two necessary directories plus one file.'
        Check (@($entries | Where-Object {-not $_.Directory}).Count -eq 1) 'Extra installation/business files entered ExactFiles.'
        Check (@($entries | Where-Object RelativePath -EQ 'settings\appsettings.json').Count -eq 1) 'Approved nested file was not captured.'
        Check ((Assert-WsmAssistiveSourceScope $spec -Native).Channel -ceq 'C') 'Physical C source was not accepted.'
        $item=[pscustomobject]@{Decision='Include';MigrationSpec=$spec}
        Check (Test-WsmAssistivePackageScope ([pscustomobject]@{Assistive=[pscustomobject]@{SourcePolicy='SourceCOnly'}}) $item) 'Approved C scope was not routed to package.'
        $spec.TransferChannel='NonC';Reject {Assert-WsmAssistiveSourceScope $spec} 'A physical C scope claimed NonC.';$spec.TransferChannel='C'
        $spec.ConfigFiles[0].RelativePath='..\outside.json';Reject {Get-WsmScopeEntries $spec $output} 'Traversal whitelist accepted.';$spec.ConfigFiles[0].RelativePath='settings\appsettings.json'
        $spec.ExcludedRelativePaths=@('settings');Reject {Get-WsmScopeEntries $spec $output} 'Excluded exact file silently disappeared.';$spec.ExcludedRelativePaths=@()
        [IO.File]::AppendAllText($config,'changed');Reject {Get-WsmScopeEntries $spec $output} 'Exact configuration drift was accepted.'
        $spec.ConfigFiles=@();Reject {Get-WsmScopeEntries $spec $output} 'Empty ExactFiles silently captured a full installation folder.'
        $spec.ContentSelection='WholeScope';$whole=@(Get-WsmScopeEntries $spec $output)
        Check (@($whole|Where-Object {-not $_.Directory}).Count -eq 3) 'Explicit business WholeScope lost files based on their extension.'
        # A forged NonC proof must not smuggle a physical C scope into the D channel.
        $proofId=('c'*64);$proofSource=(Get-WsmMachineIdentity).Fingerprint
        $proofItem=[pscustomobject]@{ItemId=$proofId;Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='FileScope';TransferChannel='NonC'}}
        $proofPlan=[pscustomobject]@{Assistive=[pscustomobject]@{};Source=[pscustomobject]@{Fingerprint=$proofSource};Items=@($proofItem)}
        $cNative=Get-WsmPhysicalPath 'C:\';$sourceNative=Get-WsmPhysicalPath $source
        $proofManifest=[pscustomobject]@{SourceCollectionProofs=@([pscustomobject]@{ItemId=$proofId;Channel='NonC';PhysicalPath=$sourceNative;SourceCPhysicalRoot=$cNative;SourceFingerprint=$proofSource;NativeVerified=$true})}
        Reject {Assert-WsmAssistiveCollectionProofs $proofManifest $proofPlan} 'Physical C evidence was accepted as a NonC source collection proof.'
        $proofManifest.SourceCollectionProofs[0].PhysicalPath='\Device\WsmFixtureOtherVolume\source'
        Assert-WsmAssistiveCollectionProofs $proofManifest $proofPlan
        Check $true 'A distinct-volume NonC proof could not be consumed.'
        # Mock only the drive resolver to exercise the native alias-boundary decision;
        # actual physical-path API behavior has its separate PhysicalPaths fixture.
        $nativeResolver=(Get-Command Get-WsmPhysicalPath).ScriptBlock
        try{
            Set-Item Function:\Get-WsmPhysicalPath -Value {param($Path)if($Path -ieq 'C:\'){'\Device\WsmFixtureC'}elseif($Path -like 'Q:\*'){'\Device\WsmFixtureC\alias-source'}else{'\Device\WsmFixtureOtherVolume\source'}}
            $aliasSpec=[pscustomobject]@{Adapter='FileScope';SourcePath='Q:\alias-source';TransferChannel='NonC'}
            Reject {Assert-WsmAssistiveSourceScope $aliasSpec -Native} 'A non-C drive alias to physical C was incorrectly classified NonC.'
            $otherSpec=[pscustomobject]@{Adapter='FileScope';SourcePath='D:\source';TransferChannel='NonC'}
            Check ((Assert-WsmAssistiveSourceScope $otherSpec -Native).Channel -ceq 'NonC') 'A genuinely distinct physical volume was rejected.'
        }finally{Set-Item Function:\Get-WsmPhysicalPath -Value $nativeResolver}
        $link=Join-Path $source 'settings\linked.json'
        New-Item -ItemType HardLink -Path $link -Target $config | Out-Null
        Reject {Assert-WsmAssistiveFileTopology $config} 'Primary member of a hard-link set was not detected.'
        Reject {Get-WsmScopeEntries $spec $output} 'WholeScope silently flattened hard-link topology.'
        $adsSource=Join-Path $source 'settings\ads-source.txt';[IO.File]::WriteAllText($adsSource,'default stream');Set-Content -LiteralPath $adsSource -Stream 'wsm-review-fixture' -Value 'alternate stream' -NoNewline
        $sourceStreams=@(Get-Item -LiteralPath $adsSource -Stream * -ErrorAction Stop)
        Check (@($sourceStreams|Where-Object Stream -CEQ 'wsm-review-fixture').Count -eq 1) 'The physical ADS fixture was not created on this filesystem.'
        Reject {Assert-WsmAssistiveFileTopology $adsSource} 'Source topology accepted a physical alternate data stream.'
        $adsSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=$source;TargetPath='D:\RestoredSettings';ExcludedRelativePaths=@();Consistency='OwnerFreeze';Metadata='DaclOwner';ConflictPolicy='Block';Owner='fixture';Evidence='fixture approval';TransferChannel='C';ContentSelection='ExactFiles';ConfigFiles=@([pscustomobject]@{RelativePath='settings\ads-source.txt';SHA256=(Get-FileHash -LiteralPath $adsSource).Hash.ToLowerInvariant();Owner='fixture';Evidence='exact file approval'})}
        Reject {Get-WsmScopeEntries $adsSpec $output} 'Exact C configuration capture accepted a source file with an alternate data stream.'
        $adsTarget=Join-Path $output 'ads-target.txt';[IO.File]::WriteAllText($adsTarget,'current target stream');Set-Content -LiteralPath $adsTarget -Stream 'wsm-review-fixture' -Value 'alternate target stream' -NoNewline
        $targetStreams=@(Get-Item -LiteralPath $adsTarget -Stream * -ErrorAction Stop)
        Check (@($targetStreams|Where-Object Stream -CEQ 'wsm-review-fixture').Count -eq 1) 'The physical target ADS fixture was not created on this filesystem.'
        Reject {Assert-WsmAssistiveFileTopology $adsTarget} 'Current target topology accepted a physical alternate data stream.'
        $metadataOnlyProbe=Join-Path $output 'metadata-only-image.bin';[byte[]]$metadataOnlyImage=New-Object byte[] 64;[Text.Encoding]::ASCII.GetBytes("MSWIM`0`0`0").CopyTo($metadataOnlyImage,0);[IO.File]::WriteAllBytes($metadataOnlyProbe,$metadataOnlyImage)
        Reject {Assert-WsmAssistiveFileTopology $metadataOnlyProbe} 'Ordinary topology verification stopped enforcing OS image content signatures.'
        Assert-WsmAssistiveFileTopology $metadataOnlyProbe -MetadataOnly
        Check $true 'Metadata-only peer observation did not retain metadata topology checks while avoiding content inspection.'
        # Isolate package and Server privilege authentication; exercise the public
        # placement consumer against real files. This is not Server qualification.
        $placement=Join-Path $root 'placement';[void][IO.Directory]::CreateDirectory($placement)
        $target=Join-Path $placement 'target';[void][IO.Directory]::CreateDirectory($target)
        $existing=Join-Path $target 'existing.config';[IO.File]::WriteAllText($existing,'same bytes')
        $hash=(Get-FileHash -LiteralPath $existing).Hash.ToLowerInvariant()
        $placementItem=[pscustomobject]@{ItemId=('a'*64);MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=(Join-Path $placement 'old-path');TargetPath=$target;Evidence='explicit reviewed mapping'}}
        $index=Join-Path $placement 'artifacts.jsonl'
        $artifactRows=@([pscustomobject]@{ItemId=$placementItem.ItemId;RelativePath='';Directory=$true;Data=$null},[pscustomobject]@{ItemId=$placementItem.ItemId;RelativePath='existing.config';Directory=$false;Data=[pscustomobject]@{Hash=$hash}},[pscustomobject]@{ItemId=$placementItem.ItemId;RelativePath='new.config';Directory=$false;Data=[pscustomobject]@{Hash=$hash}})
        [IO.File]::WriteAllLines($index,@($artifactRows|ForEach-Object {ConvertTo-Json $_ -Compress -Depth 5}),(New-Object Text.UTF8Encoding($false)))
        $script:placementFixture=[pscustomobject]@{Plan=[pscustomobject]@{PairId=[Guid]::NewGuid().ToString();Target=(Get-WsmMachineIdentity);Items=@($placementItem)};Manifest=[pscustomobject]@{ArtifactsHash=(Get-FileHash -LiteralPath $index).Hash.ToLowerInvariant()}}
        function Test-WsmMigrationPackage {param($ManifestPath,$ExpectedHash) $script:placementFixture}
        function Assert-WsmMigrationHost {param($Machine,$Fingerprint) if($Machine.Fingerprint -cne $Fingerprint){throw 'Fixture host identity mismatch.'}}
        $preview=Get-WsmFilePlacementPreview -ManifestPath (Join-Path $placement 'manifest.json') -ExpectedHash ('b'*64)
        Check (($preview.Rows|Where-Object Directory).PlacementStatus -ceq 'DirectoryAlreadyExists') 'Existing directory incorrectly blocks new files.'
        Check (($preview.Rows|Where-Object RelativePath -CEQ 'existing.config').PlacementStatus -ceq 'BlockedConflict') 'Matching external file was overwritten or granted ownership.'
        Check (($preview.Rows|Where-Object RelativePath -CEQ 'new.config').PlacementStatus -ceq 'CanPlace') 'New file in existing directory was incorrectly blocked.'
        Check ($preview.Blocked -eq 1) 'Conflict count does not describe per-file conflicts.'
        Set-Content -LiteralPath $existing -Stream 'wsm-placement-review-fixture' -Value 'alternate stream' -NoNewline
        $adsPlacement=Get-WsmFilePlacementPreview -ManifestPath (Join-Path $placement 'manifest.json') -ExpectedHash ('b'*64)
        $adsPlacementRow=@($adsPlacement.Rows|Where-Object RelativePath -CEQ 'existing.config')[0]
        Check ($adsPlacementRow.PlacementStatus -eq 'BlockedConflict' -and $adsPlacementRow.Reason -match 'special file topology|alternate data streams') 'Current ADS destination topology was not surfaced as a manual placement conflict.'
        Check (@($preview.Rows|Where-Object {$_.EffectivePath -or $_.EffectivePathStatus -cne 'NotObserved'}).Count -eq 0) 'Preservation was falsely reported as an effective configuration path.'
        Check (@($preview.Rows|Where-Object {$_.OriginalPathStatus -cne 'Missing' -or -not $_.OriginalPathChangedByApprovedMapping}).Count -eq 0) 'Original-path observations or explicit mapping are lost.'
        # A not-yet-created destination can still alias a protected physical root.
        # The preview must check the root before saying the artifact can be placed.
        $missingAliasRoot=Join-Path $placement 'missing-protected-alias'
        $placementItem.MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=(Join-Path $placement 'source');TargetPath=$missingAliasRoot;ContentSelection='WholeScope';Evidence='Reviewed isolated fixture mapping'}
        $physicalResolver=(Get-Command Get-WsmPhysicalPath -CommandType Function).ScriptBlock
        try{
            Set-Item Function:\script:Get-WsmPhysicalPath -Value {param([string]$Path)$full=[IO.Path]::GetFullPath($Path);$targetRoot=[IO.Path]::GetFullPath($script:missingAliasRoot);if($full -ieq $targetRoot -or $full.StartsWith($targetRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){return '\Device\HarddiskVolume123\Windows\System32\missing-target'}; '\Device\HarddiskVolume123\Users\Fixture\Unrelated'}
            & $module {param($target) $script:missingAliasRoot=$target} $missingAliasRoot
            $missingAliasPreview=Get-WsmFilePlacementPreview -ManifestPath (Join-Path $placement 'manifest.json') -ExpectedHash ('b'*64)
            Check (@($missingAliasPreview.Rows|Where-Object PlacementStatus -EQ 'CanPlace').Count -eq 0) 'Preview said CanPlace for a missing target whose physical alias is a protected Windows root.'
            Check ($missingAliasPreview.Blocked -gt 0) 'Preview did not count the rejected physical target alias as blocked.'
            Check (-not [IO.Directory]::Exists($missingAliasRoot)) 'Preview created the missing physical-alias target while checking it.'
        }finally{Set-Item Function:\script:Get-WsmPhysicalPath -Value $physicalResolver}
        $exactPlacementRoot=Join-Path $placement 'exact-programfiles-target';[void][IO.Directory]::CreateDirectory($exactPlacementRoot)
        $exactPlacementText='{"site":"fixture"}';$exactPlacementFile=Join-Path $exactPlacementRoot 'appsettings.json';[IO.File]::WriteAllText($exactPlacementFile,$exactPlacementText)
        $exactPlacementHash=(Get-FileHash -LiteralPath $exactPlacementFile -Algorithm SHA256).Hash.ToLowerInvariant()
        $placementItem.MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=(Join-Path $placement 'source');TargetPath=$exactPlacementRoot;ContentSelection='ExactFiles';Evidence='Reviewed exact config placement';ConfigFiles=@([pscustomobject]@{RelativePath='appsettings.json';SHA256=$exactPlacementHash;Owner='Fixture owner';Evidence='reviewed exact configuration hash'})}
        $artifactRows=@([pscustomobject]@{ItemId=$placementItem.ItemId;RelativePath='';Directory=$true;Data=$null},[pscustomobject]@{ItemId=$placementItem.ItemId;RelativePath='appsettings.json';Directory=$false;Data=[pscustomobject]@{Hash=$exactPlacementHash}})
        [IO.File]::WriteAllLines($index,@($artifactRows|ForEach-Object {ConvertTo-Json $_ -Compress -Depth 5}),(New-Object Text.UTF8Encoding($false)))
        $script:placementFixture.Manifest.ArtifactsHash=(Get-FileHash -LiteralPath $index -Algorithm SHA256).Hash.ToLowerInvariant()
        & $module {param($target) $script:exactPlacementRoot=$target} $exactPlacementRoot
        $physicalResolver=(Get-Command Get-WsmPhysicalPath -CommandType Function).ScriptBlock
        try{
            Set-Item Function:\script:Get-WsmPhysicalPath -Value {param([string]$Path)$base='\Device\HarddiskVolume123\Program Files\Fixture\Target';$full=[IO.Path]::GetFullPath($Path);$targetRoot=[IO.Path]::GetFullPath($script:exactPlacementRoot);if($full -ieq $targetRoot){return $base};if($full.StartsWith($targetRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){return ($base+'\'+$full.Substring($targetRoot.TrimEnd('\').Length).TrimStart('\'))};'\Device\HarddiskVolume123\Users\Fixture\Unrelated'}
            $exactPlacement=Get-WsmFilePlacementPreview -ManifestPath (Join-Path $placement 'manifest.json') -ExpectedHash ('b'*64)
            $exactPlacementRow=@($exactPlacement.Rows|Where-Object RelativePath -CEQ 'appsettings.json')[0]
            Check ($exactPlacementRow.PlacementStatus -ceq 'BlockedConflict' -and $exactPlacementRow.ObservedHash -ceq $exactPlacementHash) 'An exact hash-bound config in a physically protected target root was misreported as a topology failure or granted ownership.'
        }finally{Set-Item Function:\script:Get-WsmPhysicalPath -Value $physicalResolver}
        Write-Host ('PASS: '+$script:checks+' physical C / exact configuration / topology / native placement checks.')
    } $root $helper
}finally{if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force}}
