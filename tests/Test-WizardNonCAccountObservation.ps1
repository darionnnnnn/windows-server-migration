#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$installed=Get-Command 'Get-WsmWizardNonCAccountObservations' -ErrorAction Stop;if($installed.ModuleName -cne $module.Name -or [IO.Path]::GetFileName($installed.ScriptBlock.File) -cne 'WizardNonCAccountObservation.ps1'){throw 'Required NonC consumer is not the installed module implementation.'}
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-nonc-acl-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    $file=Join-Path $root 'metadata-only.txt'
    [IO.File]::WriteAllText($file,'fixture bytes must not be read by the ACL observer')
    $observed=& $module {
        param($File,$Root)
        $principals=@{}
        $unresolved=Get-WsmWizardNonCObservedAclPrincipals $File $principals
        $inRoot=Get-WsmWizardNonCPathUnderPhysicalRoot $File $Root
        $escaped=Get-WsmWizardNonCPathUnderPhysicalRoot (Join-Path $Root '..\outside.txt') $Root
        $nativeChild=Get-WsmWizardNonCPhysicalPathUnderRoot '\Device\HarddiskVolume9\business\one' '\Device\HarddiskVolume9\business'
        $nativeSibling=Get-WsmWizardNonCPhysicalPathUnderRoot '\Device\HarddiskVolume90\business\one' '\Device\HarddiskVolume9\business'
        $proofRows=@([pscustomobject]@{SHA256=('a'*64);Proof=[pscustomobject]@{LocalPhysicalRoot='\Device\HarddiskVolume9\business';PeerName='source-peer';ShareName='ShareOne'}},[pscustomobject]@{SHA256=('b'*64);Proof=[pscustomobject]@{LocalPhysicalRoot='\Device\HarddiskVolume10\business';PeerName='source-peer';ShareName='ShareTwo'}})
        $covered=Get-WsmWizardNonCSourceProofForCollection ([pscustomobject]@{PhysicalPath='\Device\HarddiskVolume10\business\scope-two'}) $proofRows
        $ambiguous=Get-WsmWizardNonCSourceProofForCollection ([pscustomobject]@{PhysicalPath='\Device\HarddiskVolume10\business\scope-two'}) @($proofRows[1],([pscustomobject]@{SHA256=('c'*64);Proof=[pscustomobject]@{LocalPhysicalRoot='\Device\HarddiskVolume10';PeerName='source-peer';ShareName='Overlapping'}}))
        $uncovered=Get-WsmWizardNonCSourceProofForCollection ([pscustomobject]@{PhysicalPath='\Device\HarddiskVolume11\business'}) $proofRows
        $builtins=@(Get-WsmWizardStableWindowsSidRows $true)
        $notWindows=@(Get-WsmWizardStableWindowsSidRows $false)
        [pscustomobject]@{Principals=@($principals.Values);Unresolved=$unresolved;InRoot=$inRoot;Escaped=$escaped;NativeChild=$nativeChild;NativeSibling=$nativeSibling;Covered=$covered;Ambiguous=$ambiguous;Uncovered=$uncovered;Builtins=$builtins;NonWindowsBuiltinCount=$notWindows.Count}
    } $file $root
    if($observed.Unresolved -ne 0){throw 'Current test filesystem ACL contained an unresolvable SID.'}
    if(@($observed.Principals|Where-Object OwnerObserved).Count -ne 1){throw 'ACL observer did not record the file owner.'}
    if(-not @($observed.Principals|Where-Object {$_.SourceSid -match '^S-1-\d+(?:-\d+)+$'}).Count){throw 'ACL observer did not return stable SID rows.'}
    if($observed.InRoot -cne 'metadata-only.txt' -or $null -ne $observed.Escaped){throw 'Physical-root matching accepted an escape or rejected a child.'}
    if($observed.NativeChild -cne 'one' -or $null -ne $observed.NativeSibling -or -not $observed.Covered -or $observed.Covered.SourceRoot -cne '\\source-peer\ShareTwo\scope-two' -or $null -ne $observed.Ambiguous -or $null -ne $observed.Uncovered){throw 'Native source collection coverage did not select exactly one matching peer share or reject overlap and uncovered roots.'}
    if(@($observed.Builtins|Where-Object {$_.stableBuiltin -and $_.sid -eq 'S-1-5-18'}).Count -ne 1 -or $observed.NonWindowsBuiltinCount -ne 0){throw 'Stable Windows SID policy is not narrowly gated.'}
    Write-Host 'PASS: ACL observation returns SID metadata only, captures owner, rejects root escape, and gates stable Windows SIDs.'
} finally {
    $full=[IO.Path]::GetFullPath($root);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if($full -ieq $tempRoot -or [IO.Path]::GetDirectoryName($full) -ine $tempRoot -or [IO.Path]::GetFileName($full) -notlike 'wsm-nonc-acl-*'){throw 'Unsafe account observation test cleanup path.'}
    if([IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop}
}
