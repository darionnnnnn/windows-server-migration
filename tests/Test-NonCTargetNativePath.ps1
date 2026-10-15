#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-native-nonc-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root)
        $native=Join-Path $Root 'settings.ini';[IO.File]::WriteAllText($native,'native path readback fixture')
        $physical=Get-WsmPhysicalPath $Root
        if($physical -notmatch '^\\Device\\HarddiskVolume'){throw 'This Windows observation did not expose a native NT volume path.'}
        $peer=[pscustomobject]@{PeerName='fixture-host';ShareName='Fixture';PeerFingerprint=('a'*64);LocalPhysicalRoot=$physical}
        $id=[guid]::NewGuid().ToString();$spec=[pscustomobject]@{Adapter='FileScope';TransferChannel='NonC';TargetPath=$Root;ContentSelection='ExactFiles'}
        $package=[pscustomobject]@{Plan=[pscustomobject]@{Items=@([pscustomobject]@{ItemId=$id;MigrationSpec=$spec})}}
        $proof=[pscustomobject]@{PeerShareProofs=@($peer)}
        $entry=[pscustomobject]@{ItemId=$id;EntryType='File';RelativePath='settings.ini';TargetPath='\\fixture-host\Fixture\settings.ini';TargetPhysicalIdentity=(Get-WsmAssistiveEndpointIdentity '\\fixture-host\Fixture\settings.ini' @($peer))}
        $resolved=Get-WsmAssistiveNonCTargetNativePath $package $entry @($entry) $proof
        if($resolved -ine $native){throw 'A matching observed NT physical root did not resolve to the exact sealed local file.'}
        if([IO.File]::ReadAllText($native) -cne 'native path readback fixture'){throw 'Read-only native path resolution changed file bytes.'}
        $entry.TargetPhysicalIdentity='different-peer'
        $rejected=$false;try{Get-WsmAssistiveNonCTargetNativePath $package $entry @($entry) $proof|Out-Null}catch{$rejected=$true};if(-not $rejected){throw 'A mismatched peer identity was accepted.'}
        $entry.TargetPhysicalIdentity=Get-WsmAssistiveEndpointIdentity $entry.TargetPath @($peer)
        $peer.LocalPhysicalRoot=$physical+'\different-scope'
        $entry.TargetPhysicalIdentity=Get-WsmAssistiveEndpointIdentity $entry.TargetPath @($peer)
        $rejected=$false;try{Get-WsmAssistiveNonCTargetNativePath $package $entry @($entry) $proof|Out-Null}catch{$rejected=$true};if(-not $rejected){throw 'A different physical scope was accepted as the sealed local destination.'}
        $entry.RelativePath='..\outside.ini'
        $rejected=$false;try{Get-WsmAssistiveNonCTargetNativePath $package $entry @($entry) $proof|Out-Null}catch{$rejected=$true};if(-not $rejected){throw 'Relative traversal was accepted.'}
        Write-Output 'PASS: actual local NT volume observation resolves the exact native Target; wrong peer, physical scope and traversal reject. Peer metadata is a fixture; no SMB authentication/transport claim.'
    } $root
} finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
    $absolute=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $absolute.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($absolute) -notlike 'wsm-native-nonc-*'){throw 'Unsafe test cleanup path.'}
    if([IO.Directory]::Exists($absolute)){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
