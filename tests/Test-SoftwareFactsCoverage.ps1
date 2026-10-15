#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
& $module {
    # Machine-wide native probes omit schema-optional ItemId. They still carry
    # facts/coverage, and must not be treated as complete installation proof.
    $row=[pscustomobject]@{Probe='InstalledPrograms';Scope='Machine';SID='';View='Registry64';Status='Partial';EvidenceKind='Registry';Count=0;ErrorKind='AccessDenied'}
    $catalog=[pscustomobject]@{Entries=@();Coverage=@($row)}
    $missing=Get-WsmAssistiveSoftwareFactsHash $catalog
    if($missing -notmatch '^[a-f0-9]{64}$'){throw 'A schema-valid missing optional ItemId could not be hashed.'}
    $row|Add-Member NoteProperty ItemId ''
    if((Get-WsmAssistiveSoftwareFactsHash $catalog) -cne $missing){throw 'Absent and explicitly empty optional ItemId changed the same coverage facts.'}
    $row.ItemId=('a'*64)
    $scoped=Get-WsmAssistiveSoftwareFactsHash $catalog
    if($scoped -ceq $missing){throw 'An explicit item binding disappeared from the coverage facts hash.'}
    $row.Status='Success'
    if((Get-WsmAssistiveSoftwareFactsHash $catalog) -ceq $scoped){throw 'A changed coverage status did not invalidate the facts hash.'}
    Write-Output 'PASS: optional coverage ItemId is normalized; explicit item and status changes remain hash-bound.'
}
