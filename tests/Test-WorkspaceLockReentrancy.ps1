#requires -Version 5.1
# Invoke-WsmLocked is reentrant only inside the module instance that already holds the workspace lock:
# a nested call for the same workspace runs directly, while another runspace (or process) still contends.
$ErrorActionPreference='Stop'
$modulePath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../src/WindowsServerMigration.psd1'))
$m=Import-Module $modulePath -Force -PassThru -DisableNameChecking
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-lock-reentry-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
try{
    $a=Join-Path $root 'a';$b=Join-Path $root 'b';[void][IO.Directory]::CreateDirectory($a);[void][IO.Directory]::CreateDirectory($b)

    # Nested same-workspace call runs inside the outer critical section and returns its value.
    $value=& $m {param($a)Invoke-WsmLocked $a {Invoke-WsmLocked $a {'inner'}}} $a
    Check ($value -ceq 'inner') 'A nested lock on the same workspace must run instead of blocking itself.'

    # Path spelling differences (trailing separator, case) are the same workspace.
    $value=& $m {param($a)Invoke-WsmLocked $a {Invoke-WsmLocked ($a.ToUpperInvariant()+'\') {'same'}}} $a
    Check ($value -ceq 'same') 'A nested lock spelled with different case or a trailing separator must be treated as the same workspace.'

    # While held, the lock file is still exclusive for any other opener (other runspaces/processes keep contending).
    $probe=& $m {param($a)Invoke-WsmLocked $a {try{$f=[IO.File]::Open((Join-Path $a '.wsm.lock'),'OpenOrCreate','ReadWrite','None');$f.Dispose();'opened'}catch [IO.IOException]{'busy'}}} $a
    Check ($probe -ceq 'busy') 'The held workspace lock file must stay exclusive while the outer call runs.'

    # A separate runspace importing its own module instance must not inherit the reentrancy.
    $other=& $m {param($a,$modulePath)Invoke-WsmLocked $a {
        $ps=[PowerShell]::Create()
        [void]$ps.AddScript({param($modulePath,$a)$ErrorActionPreference='Stop';$n=Import-Module $modulePath -Force -PassThru -DisableNameChecking;try{& $n {param($a)Invoke-WsmLocked $a {'entered'}} $a}catch{'contended'}}).AddArgument($modulePath).AddArgument($a)
        try{@($ps.Invoke())[-1]}finally{$ps.Dispose()}
    }} $a $modulePath
    Check ($other -ceq 'contended') ('Another runspace entered a workspace lock held by this runspace: '+$other)

    # A different workspace nested inside still acquires its own lock (and releases it).
    $value=& $m {param($a,$b)Invoke-WsmLocked $a {Invoke-WsmLocked $b {'other'}}} $a $b
    Check ($value -ceq 'other') 'A nested lock on a different workspace must acquire normally.'

    # After the outer call ends (normally or by exception) the lock is released and the held set is clean.
    try{& $m {param($a)Invoke-WsmLocked $a {Invoke-WsmLocked $a {throw 'boom'}}} $a}catch{}
    $f=[IO.File]::Open((Join-Path $a '.wsm.lock'),'OpenOrCreate','ReadWrite','None');$f.Dispose()
    $script:checks++
    $held=& $m {if(Test-Path variable:script:WsmHeldWorkspaceLocks){@($script:WsmHeldWorkspaceLocks).Count}else{0}}
    Check ($held -eq 0) 'The held-lock set must be empty after the outer call ends, including after an exception.'

    # An outer call held by a foreign opener still times out instead of being treated as reentrant.
    $foreign=[IO.File]::Open((Join-Path $b '.wsm.lock'),'OpenOrCreate','ReadWrite','None')
    try{$entered=$false;try{& $m {param($b)Invoke-WsmLocked $b {'x'}} $b|Out-Null;$entered=$true}catch{};Check (-not $entered) 'A lock held by another opener must not be entered.'}finally{$foreign.Dispose()}

    Write-Host ('PASS: '+$checks+' workspace lock reentrancy checks (same runspace nested, path spelling, exclusivity, other runspace contended, release after exception).')
}finally{
    try{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop}catch{Write-Warning ('cleanup: '+$_.Exception.Message)}
}
