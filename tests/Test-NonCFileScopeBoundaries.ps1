#requires -Version 5.1
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force
. (Join-Path $PSScriptRoot '..\src\Core.ps1')
. (Join-Path $PSScriptRoot '..\src\MigrationContracts.ps1')
. (Join-Path $PSScriptRoot '..\src\AdvancedReview.ps1')
. (Join-Path $PSScriptRoot '..\src\PhysicalPaths.ps1')
. (Join-Path $PSScriptRoot '..\src\FileScopeGuard.ps1')
. (Join-Path $PSScriptRoot '..\src\AssistiveFiles.ps1')
. (Join-Path $PSScriptRoot '..\src\AssistiveResources.ps1')
. (Join-Path $PSScriptRoot '..\src\Cancellation.ps1')
. (Join-Path $PSScriptRoot '..\src\AssistiveNonC.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-nonc-boundaries-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Reject([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed $Message}
try{
    # The resolver seam returns controlled native aliases for real isolated temp
    # paths. It never creates or opens anything beneath Windows/Program Files.
    $physicalResolver=(Get-Command Get-WsmPhysicalPath -CommandType Function).ScriptBlock
    $script:boundaryAliasMode='Safe'
    Set-Item Function:\Get-WsmPhysicalPath -Value {
        param([string]$Path)
        $full=[IO.Path]::GetFullPath($Path)
        $root=[IO.Path]::GetFullPath($script:boundaryAliasPath)
        if($full -ieq $root){$tail=''}elseif($full.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){$tail=$full.Substring($root.TrimEnd('\').Length).TrimStart('\')}else{return & $script:boundaryOriginalResolver $Path}
        switch($script:boundaryAliasMode){
            'Windows' {$base='\Device\HarddiskVolume123\Windows\System32'}
            'ProgramFiles' {$base='\Device\HarddiskVolume123\Program Files\Fixture'}
            default {$base='\Device\HarddiskVolume123\Data\Fixture'}
        }
        if($tail){$base+'\'+$tail}else{$base}
    }
    $script:boundaryOriginalResolver=$physicalResolver
    $script:boundaryAliasPath=$root

    $targetRoot=Join-Path $root 'target-root'
    $wholeSpec=[pscustomobject]@{Adapter='FileScope';TargetPath=$targetRoot;ContentSelection='WholeScope'}
    $missingRoot=$targetRoot
    Assert-WsmAssistiveNonCTargetBoundary -Path $missingRoot -PeerShareProofs @() -Spec $wholeSpec -RelativePath '' -IsDirectory
    Check (-not [IO.Directory]::Exists($missingRoot)) 'Root-relative empty target was not accepted as a path-only pre-write check.'

    foreach($mode in @('Windows','ProgramFiles')){
        $script:boundaryAliasMode=$mode
        $blockedTarget=Join-Path $targetRoot ('future-'+$mode+'\payload.bin')
        Reject {Assert-WsmAssistiveNonCTargetBoundary -Path $blockedTarget -PeerShareProofs @() -Spec $wholeSpec -RelativePath ('future-'+$mode+'\payload.bin')} "A nonexistent target resolving into $mode was not rejected before creation."
        Check (-not [IO.Directory]::Exists((Split-Path -Parent $blockedTarget)) -and -not [IO.File]::Exists($blockedTarget)) "The $mode alias fixture created target content before rejection."
    }

    $script:boundaryAliasMode='ProgramFiles'
    $exactRoot=Join-Path $root 'exact-target';$nested=Join-Path $exactRoot 'nested';[void][IO.Directory]::CreateDirectory($nested)
    $configPath=Join-Path $nested 'appsettings.json';[IO.File]::WriteAllText($configPath,'{"fixture":true}')
    $configHash=(Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $exactSpec=[pscustomobject]@{Adapter='FileScope';TargetPath=$exactRoot;ContentSelection='ExactFiles';ConfigFiles=@([pscustomobject]@{RelativePath='nested\appsettings.json';SHA256=$configHash})}
    Assert-WsmAssistiveNonCTargetBoundary -Path $exactRoot -PeerShareProofs @() -Spec $exactSpec -RelativePath '' -IsDirectory
    Assert-WsmAssistiveNonCTargetBoundary -Path $nested -PeerShareProofs @() -Spec $exactSpec -RelativePath 'nested' -IsDirectory
    Assert-WsmAssistiveNonCTargetBoundary -Path $configPath -PeerShareProofs @() -Spec $exactSpec -RelativePath 'nested\appsettings.json'
    Check $true 'Reviewed ExactFiles target root, nested directory ancestor and exact file failed the controlled protected physical alias fixture.'
    $unlistedBinary=Join-Path $nested 'unlisted.exe'
    Reject {Assert-WsmAssistiveNonCTargetBoundary -Path $unlistedBinary -PeerShareProofs @() -Spec $exactSpec -RelativePath 'unlisted.exe'} 'An unlisted executable was accepted by the ExactFiles path-only target boundary.'

    # The execution consumer re-expands the sealed whitelist and compares every
    # row before target writes; an injected arbitrary/binary member must fail.
    $sourceRoot=Join-Path $root 'exact-source';[void][IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'nested'))
    $sourceConfig=Join-Path $sourceRoot 'nested\appsettings.json';[IO.File]::WriteAllText($sourceConfig,'{"fixture":"source"}')
    $sourceHash=(Get-FileHash -LiteralPath $sourceConfig -Algorithm SHA256).Hash.ToLowerInvariant()
    $sourceSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=$sourceRoot;TargetPath=$exactRoot;ContentSelection='ExactFiles';TransferChannel='NonC';ConfigFiles=@([pscustomobject]@{RelativePath='nested\appsettings.json';SHA256=$sourceHash})}
    $itemId='c'*64;$targetProof=New-WsmAssistiveTargetPhysicalProof -TargetHostId ([Guid]::NewGuid().ToString()) -ApprovedTargetRoots @($exactRoot)
    $rows=@(Get-WsmAssistiveTransferScopeRows -ItemId $itemId -SourceRoot $sourceRoot -TargetRoot $exactRoot -Spec $sourceSpec -Channel NonC -ConsumerRefs @('fixture:consumer') -AccountMap ([pscustomobject]@{}) -PeerProof $null -TargetPeerProofs @($targetProof.PeerShareProofs) -ProviderId '' -CollectionPhysicalPath (Get-WsmPhysicalPath $sourceRoot))
    $sealed=[pscustomobject]@{Items=@([pscustomobject]@{ItemId=$itemId;Decision='Include';MigrationSpec=$sourceSpec})}
    $manifest=[pscustomobject]@{SourceCollectionProofs=@([pscustomobject]@{ItemId=$itemId;PhysicalPath=(Get-WsmPhysicalPath $sourceRoot)})}
    $transfer=[pscustomobject]@{Entries=$rows;Channel='NonC';SourcePeerShareProofs=@();TargetPhysicalProof=$targetProof;ProviderId=''}
    Check ((Get-WsmAssistiveNonCScopeErrors $transfer $sealed $manifest).Count -eq 0) 'The unchanged exact whitelist failed sealed-scope re-expansion.'
    $injected=$rows[0].PSObject.Copy();$injected.RelativePath='nested\unlisted.exe';$injected.SourcePath=Join-Path $sourceRoot $injected.RelativePath;$injected.OriginalSourcePath=$injected.SourcePath;$injected.TargetPath=Join-Path $exactRoot $injected.RelativePath;$injected.SourceSHA256=('a'*64);$injected.Bytes=1;$injected.EntryId=Get-WsmHashText ($itemId+'|File|nested\unlisted.exe')
    $transfer.Entries=@($rows)+@($injected)
    Check ((Get-WsmAssistiveNonCScopeErrors $transfer $sealed $manifest).ContainsKey($itemId)) 'The true transfer consumer accepted an injected unlisted binary outside the exact whitelist.'

    # Peer mapping is a pure proof-bound relative-path transform; no UNC I/O or
    # generic physical resolver call occurs in this fixture.
    $peer=[pscustomobject]@{PeerName='fixture-peer';ShareName='data';LocalPhysicalRoot='\Device\HarddiskVolume123\Program Files\PeerData';PeerFingerprint=('d'*64)}
    $mapped=Resolve-WsmAssistivePeerPhysicalPath '\\fixture-peer\data\nested\appsettings.json' $peer
    Check ($mapped -ceq '\Device\HarddiskVolume123\Program Files\PeerData\nested\appsettings.json') 'Reviewed peer proof did not preserve the exact share-relative mapping.'

    # Metadata-only topology must not invoke content-signature inspection.
    $script:boundaryAliasMode='Safe'
    $metadataPath=Join-Path $root 'metadata-only.bin';[byte[]]$image=New-Object byte[] 64;[Text.Encoding]::ASCII.GetBytes("MSWIM`0`0`0").CopyTo($image,0);[IO.File]::WriteAllBytes($metadataPath,$image)
    $contentGuard=(Get-Command Assert-WsmFileScopeContent -CommandType Function).ScriptBlock
    try{
        Set-Item Function:\Assert-WsmFileScopeContent -Value {throw 'MetadataOnly attempted to read file content.'}
        Assert-WsmAssistiveFileTopology $metadataPath -MetadataOnly
        Check $true 'Metadata-only topology invoked the file-content signature guard.'
    }finally{Set-Item Function:\Assert-WsmFileScopeContent -Value $contentGuard}

    Write-Output ("PASS: {0} isolated NonC FileScope boundary checks." -f $checks)
}finally{
    Set-Item Function:\Get-WsmPhysicalPath -Value $physicalResolver
    Remove-Item -LiteralPath $root -Recurse -Force
}
