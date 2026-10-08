#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
& $module {
    $item=[pscustomobject]@{MigrationSpec=[pscustomobject]@{Adapter='FileScope';Metadata='DaclOwner'}}
    $record=[pscustomobject]@{ItemId=('a'*64);RelativePath='file.txt';Directory=$false;Metadata=[pscustomobject]@{Sddl='O:SYG:SYD:(A;;FA;;;SY)';MetadataMode='DaclOwner';Attributes=32;CreationUtc='2026-10-08T00:00:00.0000000Z';LastWriteUtc='2026-10-08T00:00:00.0000000Z'};Data=[pscustomobject]@{Bytes=0;Hash=('a'*64);Chunks=@()}}
    Assert-WsmArtifactRecord $record $item
    foreach($bad in @('Boolean','Attributes','MetadataMode','UnzonedTime','NegativeBytes','ExtraData','WrongAdapter','DirectoryBytes')){
        $row=ConvertFrom-WsmJson ($record | ConvertTo-Json -Depth 15);$selected=ConvertFrom-WsmJson ($item | ConvertTo-Json -Depth 15)
        switch($bad){Boolean{$row.Directory='false'}Attributes{$row.Metadata.Attributes=1.5}MetadataMode{$row.Metadata.MetadataMode='DaclOwnerSacl'}UnzonedTime{$row.Metadata.LastWriteUtc='2026-10-08T00:00:00'}NegativeBytes{$row.Data.Bytes=-1}ExtraData{$row.Data | Add-Member NoteProperty Script 'unapproved'}WrongAdapter{$selected.MigrationSpec.Adapter='Service'}DirectoryBytes{$row.Directory=$true;$row.Metadata.Attributes=16}}
        $blocked=$false;try{Assert-WsmArtifactRecord $row $selected}catch{$blocked=$true};if(-not $blocked){throw ('Malformed artifact accepted: '+$bad)}
    }
    $record.Directory=$true;$record.Metadata.Attributes=16;$record.Data=$null;Assert-WsmArtifactRecord $record $item
    if('File.TXT'.ToUpperInvariant() -cne 'file.txt'.ToUpperInvariant()){throw 'Case-collision normalization failed'}
}
Write-Host 'PASS: strict artifact boolean/type, metadata mode, attributes, UTC, byte/data fields and payload adapter contract.'
