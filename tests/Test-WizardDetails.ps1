#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('wsm-wizard-details-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
try {
    & $module {
        param($Fixture,$Helper)
        . $Helper
        $source=Join-Path $Fixture 'source';$output=Join-Path $Fixture 'output'
        [void][IO.Directory]::CreateDirectory($source);[void][IO.Directory]::CreateDirectory($output)
        [void][IO.Directory]::CreateDirectory((Join-Path $source 'excluded'))
        [IO.File]::WriteAllText((Join-Path $source 'alpha.ini'),'SECRET-CONTENT-MUST-NOT-BE-READ-INTO-DETAILS')
        [IO.File]::WriteAllText((Join-Path $source 'excluded\skip.txt'),'excluded')
        $item=[pscustomobject]@{ItemId=('a'*64);MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=$source;ExcludedRelativePaths=@('excluded')};Settings=[pscustomobject]@{Path='C:\does-not-exist\observed.ini';SHA256=('b'*64)}}
        $projected=@(Get-WsmWizardFileDetails $item)
        if($projected.Count -ne 1 -or $projected[0].status -cne 'CapturedEvidence'){throw 'Stored evidence projection failed.'}
        $result=Export-WsmWizardFileDetails $item $output
        $record=Read-WsmJson $result.Path
        if($record.Status -cne 'Complete' -or $record.Entries.Count -ne 2 -or $record.ContentRead -or $record.BackupVerified){throw 'Real file metadata listing is not truthful.'}
        $row=@($record.Entries|Where-Object path -CEQ 'alpha.ini')
        if($row.Count -ne 1 -or $row[0].bytes -ne (New-Object IO.FileInfo((Join-Path $source 'alpha.ini'))).Length){throw 'Real file metadata does not match readback.'}
        if([IO.File]::ReadAllText($result.Path).Contains('SECRET-CONTENT-MUST-NOT-BE-READ-INTO-DETAILS')){throw 'Listing captured file contents.'}
        if((Get-FileHash -LiteralPath $result.Path -Algorithm SHA256).Hash -ine $result.SHA256){throw 'Durable details hash mismatch.'}
        $verified=Read-WsmWizardFileDetails $result.Path $result.SHA256 $output $item
        if($verified.Entries.Count -ne 2){throw 'Verified readback lost entries.'}
        $blocked=$false;try{Read-WsmWizardFileDetails $result.Path ('0'*64) $output $item|Out-Null}catch{$blocked=$true};if(-not $blocked){throw 'Changed hash was accepted.'}
        $priorSource=$item.MigrationSpec.SourcePath;$item.MigrationSpec.SourcePath=Join-Path $Fixture 'different'
        $blocked=$false;try{Read-WsmWizardFileDetails $result.Path $result.SHA256 $output $item|Out-Null}catch{$blocked=$true};if(-not $blocked){throw 'Changed scope was accepted.'};$item.MigrationSpec.SourcePath=$priorSource
        $bounded=Export-WsmWizardFileDetails $item $output -MaxEntries 1
        if($bounded.Status -cne 'Partial' -or $bounded.GapCount -lt 1){throw 'Bounded listing silently reported complete.'}
        $blocked=$false;try{Export-WsmWizardFileDetails $item $source|Out-Null}catch{$blocked=$true};if(-not $blocked){throw 'Output overlap was accepted.'}
        foreach($unsafe in @('\\unreachable.invalid\share\root','C:relative','\\?\C:\fixture','C:\fixture:stream','C:\scope\NUL','C:\scope\con.txt','C:\scope\LPT1.','C:\scope\COM¹.log')){
            $blocked=$false;try{Assert-WsmWizardDetailLocalPath $unsafe|Out-Null}catch{$blocked=$true};if(-not $blocked){throw 'Unsafe path was accepted.'}
        }
        $outside=Join-Path $Fixture 'outside';[void][IO.Directory]::CreateDirectory($outside);[IO.File]::WriteAllText((Join-Path $outside 'outside-secret.ini'),'outside')
        $junction=Join-Path $source 'junction';New-Item -ItemType Junction -Path $junction -Target $outside|Out-Null
        try{
            $guarded=Export-WsmWizardFileDetails $item $output;$guardRecord=Read-WsmJson $guarded.Path
            if($guarded.Status -cne 'Partial' -or @($guardRecord.Entries|Where-Object {$_.path -like '*outside-secret*'}).Count){throw 'Junction listing crossed the boundary.'}
            $blocked=$false;try{Assert-WsmWizardDetailLocalPath (Join-Path $junction 'outside-secret.ini')|Out-Null}catch{$blocked=$true};if(-not $blocked){throw 'Ancestor junction was accepted.'}
        }finally{(Get-Item -LiteralPath $junction).Delete()}
        $item.MigrationSpec|Add-Member NoteProperty ContentSelection ExactFiles
        $item.MigrationSpec|Add-Member NoteProperty ConfigFiles @([pscustomobject]@{RelativePath='alpha.ini';SHA256=('c'*64)})
        $exact=Export-WsmWizardFileDetails $item $output;$exactRecord=Read-WsmJson $exact.Path
        if($exactRecord.Entries.Count -ne 1 -or $exactRecord.Entries[0].path -cne 'alpha.ini'){throw 'Exact-file listing enumerated unrelated files.'}
        Write-Host 'PASS: durable real metadata, exact files, excluded paths, budgets, overlap, UNC/device/ADS and junction boundaries; no file contents or approval.'
    } $fixture (Join-Path $PSScriptRoot '..\src\WizardDetails.ps1')
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'wsm-wizard-details-*'){throw 'Unsafe cleanup path.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
