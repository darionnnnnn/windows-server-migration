#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Reject([scriptblock]$Action,[string]$Message){$rejected=$false;try{& $Action|Out-Null}catch{$rejected=$true};Check $rejected $Message}
$sourceHostId='11111111-2222-3333-4444-555555555555'
$sourceFingerprint='a'*64
$itemId='b'*64
$proofHash='c'*64
$scopePath='D:\reviewed\finance'
$collectionPath='\Device\HarddiskVolume17\shares\finance'
$spec=[pscustomobject]@{Adapter='FileScope';SourcePath=$scopePath;TransferChannel='NonC'}
$collection=[pscustomobject]@{ItemId=$itemId;NativeVerified=$true;SourceFingerprint=$sourceFingerprint;Channel='NonC';PhysicalPath=$collectionPath}
$peer=[pscustomobject]@{Kind='AssistivePeerShareProof';PeerHostId=$sourceHostId;PeerFingerprint=$sourceFingerprint;PeerName='source-peer';ShareName='data';LocalPhysicalRoot='\Device\HarddiskVolume17\shares';ProofHash=$proofHash}
$uncEntry=[pscustomobject]@{ItemId=$itemId;EntryType='File';RelativePath='sub\settings.ini';SourcePath='\\source-peer\data\finance\sub\settings.ini';OriginalSourcePath='D:\reviewed\finance\sub\settings.ini';SourcePeerFingerprint=$sourceFingerprint;SourcePeerProofHash=$proofHash}
$localEntry=[pscustomobject]@{ItemId=$itemId;EntryType='File';RelativePath='sub\settings.ini';SourcePath='D:\reviewed\finance\sub\settings.ini';OriginalSourcePath='D:\reviewed\finance\sub\settings.ini';SourcePeerFingerprint='';SourcePeerProofHash=''}
function Invoke-SourceBinding($Entry,[object[]]$PeerProofs=@()){
    & $script:module {
        param($Row,$Spec,$Collection,$Proofs,$HostId,$Fingerprint)
        function script:Get-WsmPhysicalPath([string]$Path){throw 'Import-only source binding must not resolve a local path to a physical NT path.'}
        Assert-WsmAssistiveNonCImportSourceBinding $Row $Spec $Collection $Proofs $HostId $Fingerprint 'NonC'|Out-Null
    } $Entry $script:spec $script:collection $PeerProofs $script:sourceHostId $script:sourceFingerprint
}
try{
    Invoke-SourceBinding $uncEntry @($peer)
    Check $true 'A correctly peer-bound UNC source beneath the sealed physical collection was rejected.'
    Invoke-SourceBinding $localEntry @()
    Check $true 'A conservative local ImportOnly source path exactly inside the sealed FileScope was rejected.'

    $bad=$uncEntry|ConvertTo-Json -Depth 12|ConvertFrom-Json;$bad.SourcePath='\\other-peer\data\finance\sub\settings.ini'
    Reject {Invoke-SourceBinding $bad @($peer)} 'ImportOnly accepted a UNC from a different peer name.'
    $bad=$uncEntry|ConvertTo-Json -Depth 12|ConvertFrom-Json;$bad.SourcePath='\\source-peer\data\outside\settings.ini'
    Reject {Invoke-SourceBinding $bad @($peer)} 'ImportOnly accepted a UNC resolving outside the sealed collection scope.'
    $bad=$uncEntry|ConvertTo-Json -Depth 12|ConvertFrom-Json;$bad.SourcePath='\\source-peer\data\finance\..\outside\settings.ini'
    Reject {Invoke-SourceBinding $bad @($peer)} 'ImportOnly accepted a source UNC containing traversal.'
    $bad=$uncEntry|ConvertTo-Json -Depth 12|ConvertFrom-Json;$bad.OriginalSourcePath='D:\reviewed\other\settings.ini'
    Reject {Invoke-SourceBinding $bad @($peer)} 'ImportOnly accepted an OriginalSourcePath outside the exact sealed logical entry scope.'
    $wrongHost=$peer|ConvertTo-Json -Depth 12|ConvertFrom-Json;$wrongHost.PeerHostId='99999999-2222-3333-4444-555555555555'
    Reject {Invoke-SourceBinding $uncEntry @($wrongHost)} 'ImportOnly accepted a peer proof from the wrong source host ID.'
    $wrongFingerprint=$peer|ConvertTo-Json -Depth 12|ConvertFrom-Json;$wrongFingerprint.PeerFingerprint='d'*64
    Reject {Invoke-SourceBinding $uncEntry @($wrongFingerprint)} 'ImportOnly accepted a peer proof with the wrong source fingerprint.'
    Write-Output ('NonC source ImportOnly binding checks passed: '+$checks)
}finally{Remove-Module $module.Name -Force -ErrorAction SilentlyContinue}
