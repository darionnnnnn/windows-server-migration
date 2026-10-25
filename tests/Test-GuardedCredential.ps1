#requires -Version 5.1
# R17 (PLAN 17.125): Get-Credential has exactly one caller, Get-WsmGuardedCredential, which stops BEFORE the call when the console input is redirected.
# ABSOLUTE RULE of this test: nothing here may ever reach the real Get-Credential cmdlet (it would open a real credential window on this machine).
# Only three kinds of checks are used:
#   1. static scans (PowerShell AST) of the product scripts;
#   2. a child process whose stdin is genuinely redirected (and closed), where Get-Credential is shadowed inside the module by a call-counting double
#      BEFORE anything runs, so even a failing guard can only reach the double, never the cmdlet;
#   3. the same double with the console state faked as interactive, to prove the double is wired in and the guard lets a real interactive call through.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$module=[IO.Path]::GetFullPath((Join-Path $repo 'src\WindowsServerMigration.psd1'))
$script:checks=0
function Check([bool]$Condition,[string]$Message){$script:checks++;if(-not $Condition){throw $Message}}

# ---------------------------------------------------------------------------------------------------------------- 1. static guard
function Find-DirectCredentialCalls([string]$Text,[string]$Label){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ('Parse errors in '+$Label+': '+$errors[0].Message)}
    $nodes=$ast.FindAll({param($node)
        ($node -is [Management.Automation.Language.StringConstantExpressionAst] -and [string]$node.Value -ieq 'Get-Credential' -and $node.Parent -is [Management.Automation.Language.CommandAst]) -or
        ($node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and [string]$node.Member.Value -ieq 'PromptForCredential') -or
        ($node -is [Management.Automation.Language.StringConstantExpressionAst] -and [string]$node.Value -ieq 'Get-Credential' -and $node.Parent -is [Management.Automation.Language.ArrayLiteralAst])
    },$true)
    foreach($node in @($nodes)){
        $inside=$false;$cursor=$node.Parent
        while($cursor){if($cursor -is [Management.Automation.Language.FunctionDefinitionAst] -and $cursor.Name -ceq 'Get-WsmGuardedCredential'){$inside=$true;break};$cursor=$cursor.Parent}
        if(-not $inside){[pscustomobject]@{File=$Label;Line=$node.Extent.StartLineNumber;Text=$node.Extent.Text}}
    }
}
# the scanner itself: it must see every way of reaching the cmdlet and must ignore the guard, comments and strings.
$scannerCases=@(
    @{Name='direct call';Text='function A { $c = Get-Credential -Message "x" }';Hits=1},
    @{Name='call in a scriptblock';Text='$b = { Get-Credential }';Hits=1},
    @{Name='call operator with a string';Text="& 'Get-Credential' -Message x";Hits=1},
    @{Name='Get-Command lookup';Text='$c = Get-Command Get-Credential';Hits=1},
    @{Name='host prompt';Text='$c = $Host.UI.PromptForCredential("t","m","u","d")';Hits=1},
    @{Name='case-insensitive spelling';Text='get-credential';Hits=1},
    @{Name='another function that is not the guard';Text='function Get-WsmGuardedCredentialX { Get-Credential }';Hits=1},
    @{Name='inside the guard';Text='function Get-WsmGuardedCredential { Get-Credential -Message $Message }';Hits=0},
    @{Name='a comment';Text='# Get-Credential is guarded';Hits=0},
    @{Name='a string literal';Text='$m = "do not call Get-Credential directly"';Hits=0}
)
foreach($case in $scannerCases){
    $found=@(Find-DirectCredentialCalls $case.Text $case.Name)
    Check ($found.Count -eq $case.Hits) ('The scanner must report '+$case.Hits+' hit(s) for "'+$case.Name+'", got '+$found.Count+'.')
}
$files=@(Get-ChildItem (Join-Path $repo 'src') -File | Where-Object Extension -In @('.ps1','.psm1'))+@(Get-Item (Join-Path $repo 'Start-ServerMigration.ps1'))
$toolsDirectory=Join-Path $repo 'tools';if([IO.Directory]::Exists($toolsDirectory)){$files+=@(Get-ChildItem $toolsDirectory -File -Filter '*.ps1')}
$hits=@()
foreach($file in $files){$hits+=@(Find-DirectCredentialCalls ([IO.File]::ReadAllText($file.FullName)) $file.Name)}
Check ($hits.Count -eq 0) ('Get-Credential must only be called inside Get-WsmGuardedCredential; direct use found: '+((@($hits|ForEach-Object{$_.File+':'+$_.Line})) -join ', '))
# every former call site goes through the guard (MigrationWizard: SecretRef gather, service challenge x2 (account known/unknown), DomainRename; OperationRequests: typed credential, typed Secrets, advanced option 4)
$wizardText=[IO.File]::ReadAllText((Join-Path $repo 'src\MigrationWizard.ps1'));$operationText=[IO.File]::ReadAllText((Join-Path $repo 'src\OperationRequests.ps1'))
$guardUses={param($text) ([regex]::Matches($text,'Get-WsmGuardedCredential -Message')).Count}
Check ((& $guardUses $wizardText) -eq 4) ('MigrationWizard.ps1 must call the guard at its 4 prompt sites, found '+(& $guardUses $wizardText))
Check ((& $guardUses $operationText) -eq 3) ('OperationRequests.ps1 must call the guard at its 3 prompt sites, found '+(& $guardUses $operationText))
# inside the guard the stop comes before the cmdlet is reached.
$coreTokens=$null;$coreErrors=$null
$coreAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'src\Core.ps1'),[ref]$coreTokens,[ref]$coreErrors)
$guardAst=@($coreAst.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-WsmGuardedCredential'},$true))
Check ($guardAst.Count -eq 1) 'Core.ps1 must define Get-WsmGuardedCredential exactly once.'
$throws=@($guardAst[0].FindAll({param($n) $n -is [Management.Automation.Language.ThrowStatementAst]},$true))
$calls=@($guardAst[0].FindAll({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and [string]$n.Value -ieq 'Get-Credential' -and $n.Parent -is [Management.Automation.Language.CommandAst]},$true))
Check ($throws.Count -ge 1 -and $calls.Count -ge 1 -and $throws[0].Extent.StartOffset -lt $calls[0].Extent.StartOffset) 'The guard must throw before it reaches Get-Credential.'
$guardParameters=@($guardAst[0].Body.ParamBlock.Parameters|ForEach-Object{$_.Name.VariablePath.UserPath})
Check ($guardParameters -ccontains 'Message' -and $guardParameters -ccontains 'UserName' -and $guardParameters -ccontains 'InputRedirected') 'The guard keeps the Get-Credential parameters plus the explicit redirection override.'

# ---------------------------------------------------------------------------------------------------------------- 2. redirected child process with a counting double
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-guardcred-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try{
    $child=Join-Path $root 'child.ps1'
    $body=@'
param([string]$ModulePath)
$ErrorActionPreference='Stop'
$m=Import-Module $ModulePath -Force -PassThru -DisableNameChecking -WarningAction SilentlyContinue
$result=[ordered]@{}
$result.redirected=[bool][Console]::IsInputRedirected
$result.realCmdletBefore=(Get-Command Get-Credential).CommandType.ToString()
# The counting double shadows Get-Credential for every function of the module BEFORE anything runs.
& $m {$script:GcCalls=0;function script:Get-Credential{param([string]$Message,[string]$UserName);$script:GcCalls++;[pscustomobject]@{UserName='double-user';Password='double-not-a-secret'}}}
$result.doubleVisible=[bool](& $m {(Get-Command Get-Credential).CommandType -eq 'Function'})
function Get-Calls { [int](& $m {$script:GcCalls}) }
function Probe([string]$Name,[scriptblock]$Body){
    $before=Get-Calls
    try{$null=& $m $Body;$outcome='returned'}
    catch{$exception=$_.Exception;$outcome=$exception.GetType().FullName+'|waiting='+$exception.Data.Contains('WsmWaitingForInput')+'|secret='+$exception.Data.Contains('WsmSecretInput')}
    $result[$Name]=$outcome
    $result[$Name+'.calls']=(Get-Calls)-$before
}
# doubles for the prompts around the credential sites (they answer, never read stdin)
& $m {
    function script:Read-WsmWizardValue{param([string]$Label,[switch]$Optional);if($Label -match 'SecretRef'){return 'ref-one'};'typed-value'}
    function script:Read-WsmTrustedJson{param($Path,$Hash);[pscustomobject]@{Action='Probe';Arguments=[pscustomobject]@{}}}
    function script:Assert-WsmEnvelope{param($Data,$Kind)}
    function script:Invoke-WsmOperationRequest{param($Path,$ExpectedHash,$Secrets);[pscustomobject]@{Status='Succeeded'}}
}
$global:serviceRequirements=@([pscustomobject]@{SecretRef='svc-ref-1';Kinds=@('Service');DisplayNames=@('Fixture service');ApprovedAccount='CONTOSO\svc'})
$global:secretPackage=[pscustomobject]@{Plan=[pscustomobject]@{Items=@([pscustomobject]@{Decision='Include';MigrationSpec=[pscustomobject]@{SecretRef='ref-a'}})}}
$advancedChoices=New-Object 'System.Collections.Generic.Queue[string]'
$runProbes={
    Probe 'guard' {Get-WsmGuardedCredential -Message 'm'}
    Probe 'guardWithUser' {Get-WsmGuardedCredential -Message 'm' -UserName 'CONTOSO\svc'}
    Probe 'serviceChallenge' {Read-WsmWizardServiceChallengeInput @('svc-ref-1') $global:serviceRequirements 6>$null}
    Probe 'secretRefs' {Read-WsmWizardSecrets $global:secretPackage}
    Probe 'advancedMenu' {$script:Choices=New-Object 'System.Collections.Generic.Queue[string]';'4','0'|ForEach-Object{$script:Choices.Enqueue($_)};function script:Read-Host{param($Prompt);$script:Choices.Dequeue()};Show-WsmMigrationMenu -Workspace 'unused' 6>$null}
}
& $runProbes
$result.redirectedCalls=Get-Calls
# Control: with the console state faked as interactive the double IS reached (so the zero above is the guard's work, not a broken double).
& $m {function script:Test-WsmConsoleInputRedirected{$false}}
Probe 'interactiveGuard' {Get-WsmGuardedCredential -Message 'm'}
Probe 'interactiveGuardWithUser' {Get-WsmGuardedCredential -Message 'm' -UserName 'CONTOSO\svc'}
Probe 'interactiveServiceChallenge' {Read-WsmWizardServiceChallengeInput @('svc-ref-1') $global:serviceRequirements 6>$null}
$result.interactiveCalls=(Get-Calls)-$result.redirectedCalls
# The explicit override can only tighten the guard (main-agent review): with the console redirected, -InputRedirected $false must still stop
# before the credential call; on an interactive console, -InputRedirected $true must stop as well.
& $m {function script:Test-WsmConsoleInputRedirected{$true}}
$before=Get-Calls
try{$null=& $m {Get-WsmGuardedCredential -Message 'm' -InputRedirected $true};$result.overrideTrue='returned'}catch{$result.overrideTrue=$_.Exception.GetType().FullName}
$result.overrideTrueCalls=(Get-Calls)-$before
$before=Get-Calls
try{$null=& $m {Get-WsmGuardedCredential -Message 'm' -InputRedirected $false};$result.overrideFalse='returned'}catch{$result.overrideFalse=$_.Exception.GetType().FullName}
$result.overrideFalseCalls=(Get-Calls)-$before
& $m {function script:Test-WsmConsoleInputRedirected{$false}}
$before=Get-Calls
try{$null=& $m {Get-WsmGuardedCredential -Message 'm' -InputRedirected $true};$result.overrideTightens='returned'}catch{$result.overrideTightens=$_.Exception.GetType().FullName}
$result.overrideTightensCalls=(Get-Calls)-$before
# The double is removed with the module; the real cmdlet is untouched.
Remove-Module WindowsServerMigration -Force
$result.realCmdletAfter=(Get-Command Get-Credential).CommandType.ToString()
$result.doubleLeaked=[bool](Test-Path Function:\Get-Credential)
Write-Output ('RESULT='+($result|ConvertTo-Json -Compress))
'@
    [IO.File]::WriteAllText($child,$body,(New-Object Text.UTF8Encoding($true)))
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=(Get-Command powershell.exe).Source
    $psi.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$child+'" -ModulePath "'+$module+'"'
    $psi.UseShellExecute=$false;$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
    $process=[Diagnostics.Process]::Start($psi)
    $process.StandardInput.Close()   # stdin is redirected and already at its end
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    if(-not $process.WaitForExit(180000)){try{$process.Kill()}catch{};throw 'The guarded-credential child did not finish.'}
    $out=$stdout.Result;$err=$stderr.Result
    $line=@($out -split "`r?`n"|Where-Object{$_ -like 'RESULT=*'})
    Check ($line.Count -eq 1) ('The child must report one RESULT line; got: '+$out+' '+$err)
    $r=$line[0].Substring(7)|ConvertFrom-Json
    Check ($r.redirected -eq $true) 'The child console input must really be redirected.'
    Check ($r.realCmdletBefore -ceq 'Cmdlet' -and $r.doubleVisible -eq $true) 'Before the probes Get-Credential is the real cmdlet outside the module and the counting double inside it.'
    foreach($name in @('guard','guardWithUser','serviceChallenge','secretRefs','advancedMenu')){
        $outcome=[string]$r.$name
        Check ($outcome -ceq 'System.IO.EndOfStreamException|waiting=True|secret=True') ('Redirected input must stop '+$name+' with a WaitingForInput EndOfStreamException before Get-Credential; got '+$outcome)
        Check ([int]$r.($name+'.calls') -eq 0) ('The Get-Credential double must not be called when stdin is redirected ('+$name+'); calls='+$r.($name+'.calls'))
    }
    Check ([int]$r.redirectedCalls -eq 0) 'The Get-Credential double count must stay 0 across all redirected prompts.'
    Check ($r.interactiveGuard -ceq 'returned' -and $r.interactiveGuardWithUser -ceq 'returned' -and $r.interactiveServiceChallenge -ne $null) 'With an interactive console the guard must pass the call through.'
    Check ([int]$r.interactiveCalls -ge 3) ('The double must be reached when the console is interactive (control); calls='+$r.interactiveCalls)
    Check ($r.overrideTrue -ceq 'System.IO.EndOfStreamException' -and [int]$r.overrideTrueCalls -eq 0 -and $r.overrideFalse -ceq 'System.IO.EndOfStreamException' -and [int]$r.overrideFalseCalls -eq 0 -and $r.overrideTightens -ceq 'System.IO.EndOfStreamException' -and [int]$r.overrideTightensCalls -eq 0) 'The -InputRedirected override may only tighten the guard: redirected input is never prompted, even with -InputRedirected $false.'
    Check ($r.realCmdletAfter -ceq 'Cmdlet' -and $r.doubleLeaked -eq $false) 'The double must be gone after the test and the real cmdlet untouched.'
    Check ($out -notmatch 'double-not-a-secret' -and $err -notmatch 'double-not-a-secret') 'The double credential must never be echoed.'
}finally{
    try{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop}catch{Write-Warning ('cleanup: '+$_.Exception.Message)}
}
Write-Host ('PASS: Get-Credential is called only by Get-WsmGuardedCredential (AST gate over '+$files.Count+' files, '+$scannerCases.Count+' scanner cases); with stdin redirected every prompt site stops with WaitingForInput before the credential call and the call-counting double stays at 0 ('+$script:checks+' checks).')
