#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\src\Core.ps1')
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('wsm-directory-protection-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
try {
    $directory=Join-Path $fixtureRoot 'controlled';[void][IO.Directory]::CreateDirectory($directory)
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $allowed=@($identity.User.Value,'S-1-5-18','S-1-5-32-544') | Select-Object -Unique
    for($attempt=0;$attempt -lt 3;$attempt++) {
        Protect-WsmDirectory $directory
        $readback=Get-Acl -LiteralPath $directory
        if(-not $readback.AreAccessRulesProtected){throw 'Controlled directory still inherits parent access.'}
        if($readback.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $identity.User.Value){throw 'Directory owner differs from the current execution identity.'}
        $rules=@($readback.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
        if($rules.Count -ne $allowed.Count){throw 'Unexpected access rule count after protection.'}
        foreach($rule in $rules) {
            if($rule.IsInherited -or $rule.IdentityReference.Value -notin $allowed -or $rule.AccessControlType -ne 'Allow' -or $rule.FileSystemRights -ne 'FullControl' -or [string]$rule.InheritanceFlags -ne 'ContainerInherit, ObjectInherit'){throw 'Unexpected access rights after protection.'}
        }
    }
    $content=Join-Path $directory 'readback.txt';[IO.File]::WriteAllText($content,'retained')
    Protect-WsmDirectory $directory
    if([IO.File]::ReadAllText($content) -cne 'retained'){throw 'Repeated directory protection altered existing contents.'}
    Write-Host 'PASS: native directory owner/DACL readback, restricted identities, inheritance, repeated reopen and retained content.'
} finally {
    $resolved=[IO.Path]::GetFullPath($fixtureRoot)
    $tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'wsm-directory-protection-*'){throw 'Unsafe fixture cleanup path.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
