#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-file-edges-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
& $module {
    param($Root)
    $ads=Join-Path $Root 'with-ads.txt';[IO.File]::WriteAllText($ads,'default stream');Set-Content -LiteralPath $ads -Stream fixture -Value 'alternate stream'
    $blocked=$false;try{Get-WsmFileMetadata $ads DaclOwner | Out-Null}catch{if($_.Exception.Message -notmatch 'ADS requires'){throw};$blocked=$true};if(-not $blocked){throw 'ADS silently omitted'}
    $locked=Join-Path $Root 'locked.bin';[IO.File]::WriteAllBytes($locked,(New-Object byte[] 65536));$blobs=Join-Path $Root 'blobs';[void][IO.Directory]::CreateDirectory($blobs);$handle=[IO.File]::Open($locked,'Open','ReadWrite','None')
    try{$blocked=$false;try{Write-WsmPayloadFile $locked $blobs 65536 | Out-Null}catch [IO.IOException]{$blocked=$true};if(-not $blocked -or @(Get-ChildItem $blobs).Count){throw 'Locked file captured or leaked partial payload'}}finally{$handle.Dispose()}
    $long=Join-Path $Root ('x'*240);$blocked=$false;try{Get-WsmScopeEntries ([pscustomobject]@{SourcePath=$long}) (Join-Path $Root 'package') | Out-Null}catch{if($_.Exception.Message -notmatch '239-character'){throw};$blocked=$true};if(-not $blocked){throw 'Unqualified long path accepted'}
} $root
$target=Join-Path $root 'junction-target';[void][IO.Directory]::CreateDirectory($target);$junction=Join-Path $root 'junction-fixture';New-Item -ItemType Junction -Path $junction -Target $target | Out-Null
& $module {
    param($Junction)
    $blocked=$false;try{Assert-WsmNoReparse (Join-Path $Junction 'child')}catch{if($_.Exception.Message -notmatch 'Reparse point requires'){throw};$blocked=$true};if(-not $blocked){throw 'Junction ancestor accepted'}
} $junction
Write-Host ('PASS: real ADS refusal, exclusively locked file without partial output, junction ancestor and explicit long-path guard. Evidence: '+$root)
