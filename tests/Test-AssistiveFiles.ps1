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
        $link=Join-Path $source 'settings\linked.json'
        New-Item -ItemType HardLink -Path $link -Target $config | Out-Null
        Reject {Assert-WsmAssistiveFileTopology $config} 'Primary member of a hard-link set was not detected.'
        Reject {Get-WsmScopeEntries $spec $output} 'WholeScope silently flattened hard-link topology.'
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
        Check (@($preview.Rows|Where-Object {$_.EffectivePath -or $_.EffectivePathStatus -cne 'NotObserved'}).Count -eq 0) 'Preservation was falsely reported as an effective configuration path.'
        Check (@($preview.Rows|Where-Object {$_.OriginalPathStatus -cne 'Missing' -or -not $_.OriginalPathChangedByApprovedMapping}).Count -eq 0) 'Original-path observations or explicit mapping are lost.'
        Write-Host ('PASS: '+$script:checks+' physical C / exact configuration / topology / native placement checks.')
    } $root $helper
}finally{if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force}}
