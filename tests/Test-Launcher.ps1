#requires -Version 5.1
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$launcher=Join-Path $repository 'Start-ServerMigration.cmd'
$content=[IO.File]::ReadAllText($launcher)
$entrySource=[IO.File]::ReadAllText((Join-Path $repository 'Start-ServerMigration.ps1'))
$compatStart=$entrySource.IndexOf('# Windows PowerShell launched from pwsh')
$compatEnd=$entrySource.IndexOf("if(`$Action -ceq 'Html'){",$compatStart)
if($compatStart -lt 0 -or $compatEnd -le $compatStart){throw 'Actual entry module compatibility preamble is missing.'}
$compatPreamble=$entrySource.Substring($compatStart,$compatEnd-$compatStart)
if($content -match '(?i)ExecutionPolicy|Set-ExecutionPolicy|\s-Command\s'){throw 'Launcher changes policy or executes interpolated commands.'}
if($content -notmatch 'Sysnative' -or $content -notmatch '-NoProfile -File'){throw 'Launcher lacks the x64 file entry.'}
if($content -match '(?<!\r)\n'){throw 'CMD launcher requires CRLF for reliable UTF-8 command parsing.'}
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm launcher '+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try{
    Copy-Item -LiteralPath $launcher -Destination (Join-Path $root 'Start-ServerMigration.cmd')
    # Deliberate entry fixture: verify the actual CMD invocation, not a migration operation.
    $stub=@'
$ErrorActionPreference='Stop'
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'invocation.json'),(@{Is64Bit=[Environment]::Is64BitProcess;Root=$PSScriptRoot;Arguments=@($args);Policy=[string](Get-ExecutionPolicy)}|ConvertTo-Json))
exit 0
'@
    [IO.File]::WriteAllText((Join-Path $root 'Start-ServerMigration.ps1'),($compatPreamble+$stub),(New-Object Text.UTF8Encoding($true)))
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$env:ComSpec
    $info.Arguments='/d /c ""'+(Join-Path $root 'Start-ServerMigration.cmd')+'""'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.RedirectStandardInput=$true
    $info.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
    $process=New-Object Diagnostics.Process;$process.StartInfo=$info
    try{
        [void]$process.Start();$process.StandardInput.Close()
        if(-not $process.WaitForExit(20000)){$process.Kill();throw 'Launcher did not exit.'}
        $stdout=$process.StandardOutput.ReadToEnd();$stderr=$process.StandardError.ReadToEnd()
        if($process.ExitCode -ne 0){throw ('Launcher failed: '+$stdout+$stderr)}
        $actual=Get-Content -LiteralPath (Join-Path $root 'invocation.json') -Raw | ConvertFrom-Json
        if(-not $actual.Is64Bit -or $actual.Root -cne $root -or @($actual.Arguments).Count){throw 'Launcher invoked the wrong architecture, directory or arguments.'}
    }finally{$process.Dispose()}
    $entryTokens=$null;$entryErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'Start-ServerMigration.ps1'),[ref]$entryTokens,[ref]$entryErrors)
    if($entryErrors.Count){throw $entryErrors[0]}
    Write-Host 'PASS launcher: actual x64 CMD invocation from a path with spaces; no policy bypass; entry AST valid.'
}finally{
    $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'wsm launcher *'){throw 'Refusing cleanup outside the owned launcher fixture.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
