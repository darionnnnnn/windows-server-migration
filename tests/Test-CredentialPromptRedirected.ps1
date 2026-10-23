#requires -Version 5.1
# The Target restore credential prompt must never read an account and password from redirected console input.
# A child Windows PowerShell gets a piped stdin (blank answer to the DEFER question, then would-be credentials);
# the prompt must stop with EndOfStreamException (WaitingForInput) instead of calling the real Get-Credential.
$ErrorActionPreference='Stop'
$module=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../src/WindowsServerMigration.psd1'))
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-credprompt-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try{
    $child=Join-Path $root 'child.ps1'
    $body=@'
param([string]$ModulePath)
$ErrorActionPreference='Stop'
$m=Import-Module $ModulePath -Force -PassThru -DisableNameChecking
try{
    & $m {Read-WsmWizardServiceChallengeInput @('svc-ref-1') @([pscustomobject]@{SecretRef='svc-ref-1';Kinds=@('Service');DisplayNames=@('Fixture service');ApprovedAccount='CONTOSO\svc'})}|Out-Null
    Write-Output 'RESULT=returned'
}catch{
    Write-Output ('RESULT='+$_.Exception.GetType().FullName)
}
'@
    [IO.File]::WriteAllText($child,$body,(New-Object Text.UTF8Encoding($true)))
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=(Get-Command powershell.exe).Source
    $psi.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$child+'" -ModulePath "'+$module+'"'
    $psi.UseShellExecute=$false;$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
    $p=[Diagnostics.Process]::Start($psi)
    $p.StandardInput.WriteLine('')
    $p.StandardInput.WriteLine('CONTOSO\svc')
    $p.StandardInput.WriteLine('P@ssw0rd-from-pipe')
    $p.StandardInput.Close()
    $stdout=$p.StandardOutput.ReadToEnd();$stderr=$p.StandardError.ReadToEnd()
    if(-not $p.WaitForExit(120000)){try{$p.Kill()}catch{};throw 'The credential prompt child did not finish (it may be waiting for interactive input).'}
    if($stdout -notmatch 'RESULT=System\.IO\.EndOfStreamException'){throw ('Redirected stdin must stop the credential prompt with EndOfStreamException; got: '+$stdout+' '+$stderr)}
    if($stdout -match 'P@ssw0rd-from-pipe' -or $stderr -match 'P@ssw0rd-from-pipe'){throw 'The piped password was echoed.'}
    Write-Host 'PASS: the Target credential prompt refuses redirected console input (EndOfStreamException -> WaitingForInput) without calling Get-Credential.'
}finally{
    try{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop}catch{Write-Warning ('cleanup: '+$_.Exception.Message)}
}
