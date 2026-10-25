#requires -Version 5.1
# S5: release manifest path safety. A single backslash, an NTFS alternate data stream colon
# and a reserved device name must each be refused before any archive byte is trusted.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-release-paths-'+[Guid]::NewGuid().ToString('N').Substring(0,10));[void][IO.Directory]::CreateDirectory($root)
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function New-ManifestOnlyArchive([string]$Name,[string]$EntryPath){
    $path=Join-Path $root ($Name+'.zip')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $manifest=[ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='ToolRelease';ToolFingerprint=('0'*64);Files=@([ordered]@{Path=$EntryPath;Bytes=1;SHA256=('0'*64)})}
    $archive=[IO.Compression.ZipFile]::Open($path,'Create')
    try{$entry=$archive.CreateEntry('release.json');$writer=New-Object IO.StreamWriter($entry.Open(),(New-Object Text.UTF8Encoding($false)));try{$writer.Write(($manifest|ConvertTo-Json -Depth 5))}finally{$writer.Dispose()}}finally{$archive.Dispose()}
    $path
}
function Get-ProjectionMessage([string]$Path){$message='';try{& $script:module {param($p)Get-WsmReleaseArchiveProjection $p|Out-Null} $Path}catch{$message=$_.Exception.Message};$message}
try {
    $control=Get-ProjectionMessage (New-ManifestOnlyArchive 'control' 'src/ok.ps1')
    Check ($control -and $control -notlike '*nonportable or unsafe path*') 'Control: a normal src/ path must pass the path check (and then fail only on the missing entry bytes).'
    $control2=Get-ProjectionMessage (New-ManifestOnlyArchive 'control2' 'docs/readme.v1.md')
    Check ($control2 -notlike '*nonportable or unsafe path*') 'Control: a dotted normal document name was wrongly treated as unsafe.'
    $cases=[ordered]@{
        'backslash-src'='src\evil.ps1'
        'backslash-only'='evil\'
        'ads-colon'='src/evil.ps1:stream'
        'ads-hidden-stream'='README.md::$DATA'
        'device-con'='src/CON'
        'device-nul-ext'='src/nul.txt'
        'device-com1-lower'='docs/com1.md'
        'device-lpt9-dot'='src/LPT9.tar.gz'
        'device-aux-mid'='tools/aux'
        'device-prn-trailing-dot'='src/prn.'
        'device-dir-segment'='src/CON/evil.ps1'
        'device-root-dir-segment'='LPT1/x.ps1'
    }
    foreach($name in $cases.Keys){
        $message=Get-ProjectionMessage (New-ManifestOnlyArchive $name $cases[$name])
        Check ($message -like '*nonportable or unsafe path*') ('S5: manifest path "'+$cases[$name]+'" ('+$name+') passed the unsafe-path check; message="'+$message+'".')
    }
    $near=Get-ProjectionMessage (New-ManifestOnlyArchive 'near-device' 'src/console.ps1')
    Check ($near -notlike '*nonportable or unsafe path*') 'Control: console.ps1 only starts with a reserved device prefix and must stay legal.'
    Write-Output ('PASS Test-ToolReleaseArchivePaths checks='+$checks+'; single backslash, colon/ADS and reserved device names are refused at the manifest path check.')
} finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
    $absolute=[IO.Path]::GetFullPath($root);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($absolute.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($absolute) -like 'wsm-release-paths-*' -and [IO.Directory]::Exists($absolute)){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
