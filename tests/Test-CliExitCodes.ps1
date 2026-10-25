#requires -Version 5.1
# R16 (PLAN 17.125): the CLI return codes are consistent across entries.
#   - -Action Operation / OperationRequest: missing -Path, missing/invalid -ExpectedHash, a missing file and a damaged JSON file are
#     contract errors (exit 4) exactly like every other -Action (they used to exit 1).
#   - -Action Menu: the status of every typed operation is remembered and the worst one is the exit code at the end (it used to be
#     discarded by "| Out-Null", so the menu always exited 0).
#   - The RESUME prompt at the end of the input is WaitingForInput (exit 2), not "InputUnavailable" (exit 3).
#   - -Action DeveloperProbe accepts a relative -Workspace (it used to exit 1).
# Real CLI child processes (stdin is closed or piped); the typed-operation statuses are driven in-process with module-scope doubles.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$entry=Join-Path $repo 'Start-ServerMigration.ps1'
$engine=Join-Path $PSHOME 'powershell.exe';if(-not (Test-Path -LiteralPath $engine)){$engine=Join-Path $PSHOME 'pwsh.exe'}
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-cli-codes-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$script:checks=0
function Check([bool]$Condition,[string]$Message){$script:checks++;if(-not $Condition){throw $Message}}
function Invoke-Cli([string[]]$CliArguments,[string[]]$InputLines=@(),[string]$WorkingDirectory=''){
    $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$engine;$psi.UseShellExecute=$false;$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
    if($WorkingDirectory){$psi.WorkingDirectory=$WorkingDirectory}
    $psi.Arguments=(@('-NoProfile','-ExecutionPolicy','Bypass','-File','"'+$entry+'"')+$CliArguments) -join ' '
    $process=[Diagnostics.Process]::Start($psi)
    try{
        foreach($line in $InputLines){$process.StandardInput.WriteLine($line)}
        $process.StandardInput.Close()
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(240000)){try{$process.Kill()}catch{};throw 'The CLI child process did not exit within 240 seconds.'}
        [pscustomobject]@{ExitCode=$process.ExitCode;Output=($stdout.Result+"`n"+$stderr.Result)}
    }finally{$process.Dispose()}
}
function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
try{
    $workspace=Join-Path $root 'ws'
    $init=Invoke-Cli @('-Action','Initialize','-Workspace',('"'+$workspace+'"'))
    Check ($init.ExitCode -eq 0) ('Initialize must return 0, got '+$init.ExitCode)

    # ---- 1. -Action Operation / OperationRequest: input problems are contract errors (4), like the other actions.
    $good=Join-Path $root 'request.json'
    [IO.File]::WriteAllText($good,'{"SchemaVersion":1,"ToolVersion":"0.4.0","Kind":"OperationRequest","Action":"NoSuchAction","Arguments":{}}',(New-Object Text.UTF8Encoding($false)))
    $goodHash=Get-Sha256 $good
    $broken=Join-Path $root 'broken.json'
    [IO.File]::WriteAllText($broken,'{ this is not json',(New-Object Text.UTF8Encoding($false)))
    $brokenHash=Get-Sha256 $broken
    $missing=Join-Path $root 'does-not-exist.json'
    $cases=@(
        @{Name='no -Path';Args=@();Pattern='-Path'},
        @{Name='blank -Path';Args=@('-Path','" "','-ExpectedHash',$goodHash);Pattern='-Path'},
        @{Name='no -ExpectedHash';Args=@('-Path',('"'+$good+'"'));Pattern='ExpectedHash'},
        @{Name='malformed -ExpectedHash';Args=@('-Path',('"'+$good+'"'),'-ExpectedHash','not-a-hash');Pattern='ExpectedHash'},
        @{Name='file does not exist';Args=@('-Path',('"'+$missing+'"'),'-ExpectedHash',$goodHash);Pattern='not found'},
        @{Name='damaged JSON';Args=@('-Path',('"'+$broken+'"'),'-ExpectedHash',$brokenHash);Pattern='JSON'},
        @{Name='unknown action in a valid file';Args=@('-Path',('"'+$good+'"'),'-ExpectedHash',$goodHash);Pattern='Unknown operation request action'}
    )
    foreach($action in @('Operation','OperationRequest')){
        foreach($case in $cases){
            $run=Invoke-Cli (@('-Action',$action,'-Workspace',('"'+$workspace+'"'))+$case.Args)
            Check ($run.ExitCode -eq 4) ('-Action '+$action+' with '+$case.Name+' must return 4, got '+$run.ExitCode+"`n"+$run.Output)
            Check ($run.Output -match $case.Pattern) ('-Action '+$action+' with '+$case.Name+' must say why ('+$case.Pattern+').'+"`n"+$run.Output)
        }
    }
    # the same kind of mistake on another action already returned 4; the entries now agree.
    $import=Invoke-Cli @('-Action','Import','-Workspace',('"'+$workspace+'"'))
    Check ($import.ExitCode -eq 4) ('-Action Import without -Path must return 4, got '+$import.ExitCode)
    # a wrong hash for a real file is not an input-shape problem and keeps failing as before (not 0).
    $wrongHash=Invoke-Cli @('-Action','Operation','-Workspace',('"'+$workspace+'"'),'-Path',('"'+$good+'"'),'-ExpectedHash',('0'*64))
    Check ($wrongHash.ExitCode -ne 0) 'A hash mismatch must never succeed.'

    # ---- 2. -Action Menu: a typed operation that fails is no longer forgotten when the menu is left with 0.
    # 22 (wizard) -> 4 (advanced) -> 2 (typed operation) -> 3 (Manager) -> action that is refused for this workspace -> back out with 0 0 0.
    $menu=@('-Action','Menu','-Workspace',('"'+$workspace+'"'))
    $failedThenExit=Invoke-Cli $menu @('22','4','2','3','WizardRuntimeProjection','0','0','0')
    Check ($failedThenExit.ExitCode -eq 1) ('A failed typed operation followed by a normal menu exit must return 1, got '+$failedThenExit.ExitCode+"`n"+$failedThenExit.Output)
    $cleanExit=Invoke-Cli $menu @('0')
    Check ($cleanExit.ExitCode -eq 0) ('Leaving the menu at once must still return 0, got '+$cleanExit.ExitCode)
    $endOfInputAfterFailure=Invoke-Cli $menu @('22','4','2','3','WizardRuntimeProjection')
    Check ($endOfInputAfterFailure.ExitCode -in @(1,3)) ('End of input after a failed typed operation must return the worse of failure (1) and input-ended (3) = 1, got '+$endOfInputAfterFailure.ExitCode)
    Check ($endOfInputAfterFailure.ExitCode -eq 1) 'The recorded failure must win over the input-ended code.'

    # ---- 3. -Action DeveloperProbe with a relative -Workspace behaves like the absolute one (it exited 1 with "must be an absolute local path").
    $relativeBase=Join-Path $root 'cwd';[void][IO.Directory]::CreateDirectory($relativeBase)
    $relative=Invoke-Cli @('-Action','DeveloperProbe','-Workspace','probe-ws') @() $relativeBase
    Check ($relative.ExitCode -ne 1) ('A relative -Workspace must no longer fail the entry with 1, got '+$relative.ExitCode+"`n"+$relative.Output)
    Check ($relative.Output -notmatch 'absolute local path') 'The relative workspace was still rejected as not absolute.'
    Check ([IO.Directory]::Exists((Join-Path $relativeBase 'probe-ws\developer-probes'))) 'The relative workspace was not resolved against the working directory.'
    $absolute=Invoke-Cli @('-Action','DeveloperProbe','-Workspace',('"'+(Join-Path $root 'abs-ws')+'"'))
    Check ($relative.ExitCode -eq $absolute.ExitCode) ('The relative and absolute workspaces must return the same code ('+$relative.ExitCode+' vs '+$absolute.ExitCode+').')
    $illegal=Invoke-Cli @('-Action','DeveloperProbe','-Workspace','"bad|name"') @() $relativeBase
    Check ($illegal.ExitCode -eq 4) ('An illegal workspace path must be a contract error (4), got '+$illegal.ExitCode)

    # ---- 4. The worst typed-operation status is the menu exit code (in-process; the module scope gets doubles, nothing touches the machine).
    $module=Import-Module (Join-Path $repo 'src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking -WarningAction SilentlyContinue
    function New-Outcome([string]$Status,[string]$ResultStatus=''){
        $result=@();if($ResultStatus){$result=@([pscustomobject]@{Status=$ResultStatus})}
        [pscustomobject]@{Status=$Status;Executed=($Status -ceq 'Applied');Action='X';Result=$result}
    }
    function Invoke-MenuWith([object[]]$Steps,[string[]]$Choices){
        # $Steps: an outcome object or an exception to throw for each typed-operation call (in order); $Choices: the menu answers.
        $captured=& $module {param($steps,$choices)
            $script:TestSteps=New-Object 'System.Collections.Generic.Queue[object]';foreach($s in $steps){$script:TestSteps.Enqueue($s)}
            $script:TestChoices=New-Object 'System.Collections.Generic.Queue[string]';foreach($c in $choices){$script:TestChoices.Enqueue($c)}
            function script:Invoke-WsmTypedTextOperation{param($Workspace,$PromptReader);$step=$script:TestSteps.Dequeue();if($step -is [Exception]){throw $step};$step}
            function script:Read-Host{param($Prompt);$script:TestChoices.Dequeue()}
            Reset-WsmMenuStatusCode
            Show-WsmMigrationMenu -Workspace 'unused' 6>$null
            Get-WsmMenuWorstStatusCode
        } $Steps $Choices
        @($captured)[-1]
    }
    try{
        Check ((Invoke-MenuWith @((New-Outcome 'Applied' 'Succeeded')) @('2','0')) -eq 0) 'A succeeded typed operation must leave the exit code 0.'
        Check ((Invoke-MenuWith @((New-Outcome 'Applied' 'Failed')) @('2','0')) -eq 1) 'A Failed result must make the menu return 1.'
        Check ((Invoke-MenuWith @((New-Outcome 'Applied' 'WaitingForInput')) @('2','0')) -eq 2) 'A WaitingForInput result must make the menu return 2.'
        Check ((Invoke-MenuWith @((New-Outcome 'Blocked')) @('2','0')) -eq 2) 'A Blocked preview must make the menu return 2.'
        Check ((Invoke-MenuWith @((New-Outcome 'Applied' 'Cancelled')) @('2','0')) -eq 3) 'A Cancelled result must make the menu return 3.'
        Check ((Invoke-MenuWith @((New-Outcome 'Cancelled')) @('2','0')) -eq 0) 'Declining the APPLY confirmation is not a failure and must leave 0.'
        # the worst value wins whatever the order is.
        Check ((Invoke-MenuWith @((New-Outcome 'Applied' 'WaitingForInput'),(New-Outcome 'Applied' 'Failed'),(New-Outcome 'Applied' 'Succeeded')) @('2','2','2','0')) -eq 1) 'Waiting, Failed, Succeeded in a row must end as 1.'
        Check ((Invoke-MenuWith @((New-Outcome 'Applied' 'Failed'),(New-Outcome 'Applied' 'WaitingForInput')) @('2','2','0')) -eq 1) 'A later waiting result must not hide an earlier failure.'
        Check ((Invoke-MenuWith @((New-Outcome 'Applied' 'Succeeded'),(New-Outcome 'Blocked')) @('2','2','0')) -eq 2) 'A later blocked preview must not be hidden by an earlier success.'
        # exceptions of the typed operation are recorded too: contract errors as 4, any other failure as 1.
        Check ((Invoke-MenuWith @((New-Object IO.InvalidDataException('contract'))) @('2','0')) -eq 4) 'A contract error must make the menu return 4.'
        Check ((Invoke-MenuWith @((New-Object InvalidOperationException('boom'))) @('2','0')) -eq 1) 'Any other exception must make the menu return 1.'
        Check ((Invoke-MenuWith @((New-Outcome 'Applied' 'WaitingForInput'),(New-Object IO.InvalidDataException('contract'))) @('2','2','0')) -eq 4) 'A contract error must outrank a waiting result.'
        # the explicit-request entry (option 4) also records what it returned.
        $advancedOutput=& $module {
            function script:Read-WsmWizardValue{param([string]$Label,[switch]$Optional);if($Label -match 'SecretRef'){return ''};'value'}
            function script:Read-WsmTrustedJson{param($Path,$Hash);[pscustomobject]@{Action='Probe';Arguments=[pscustomobject]@{}}}
            function script:Assert-WsmEnvelope{param($Data,$Kind)}
            function script:Invoke-WsmOperationRequest{param($Path,$ExpectedHash,$Secrets);[pscustomobject]@{Status='Failed'}}
            $script:AdvancedChoices=New-Object 'System.Collections.Generic.Queue[string]';'4','0'|ForEach-Object{$script:AdvancedChoices.Enqueue($_)}
            function script:Read-Host{param($Prompt);$script:AdvancedChoices.Dequeue()}
            Reset-WsmMenuStatusCode
            Show-WsmMigrationMenu -Workspace 'unused' 6>$null
            Get-WsmMenuWorstStatusCode
        }
        $advanced=@($advancedOutput)[-1]
        Check ($advanced -eq 1) 'A Failed result of the explicit OperationRequest entry must make the menu return 1.'
    }finally{Remove-Module WindowsServerMigration -Force -ErrorAction SilentlyContinue}

    # ---- 5. RESUME at the end of the input is WaitingForInput (exit 2), not InputUnavailable (exit 3).
    $module=Import-Module (Join-Path $repo 'src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking -WarningAction SilentlyContinue
    try{
        $parent=[Guid]::NewGuid().ToString('D')
        $outcome=& $module {param($parent)
            function script:Get-WsmWizardTargetRestoreResumePreview{param($Workspace,$PairId,$GeneralHostEvidence);[pscustomobject]@{Resumable=$true;PreviewCurrent=$true;ParentOperationId=$parent;PendingCount=2;ChallengeState='';PreviewHash=('a'*64)}}
            function script:Read-WsmWizardValue{param([string]$Label,[switch]$Optional);throw (New-Object IO.EndOfStreamException('Console input ended.'))}
            $package=[pscustomobject]@{Manifest=[pscustomobject]@{PairId='pair-1'}}
            try{$value=Invoke-WsmWizardTargetRestoreResumeFlow 'work-root' 'state-dir' $package @() 6>$null;[pscustomobject]@{Threw=$false;Value=$value}}
            catch{[pscustomobject]@{Threw=$true;Type=$_.Exception.GetType().FullName;Waiting=$_.Exception.Data.Contains('WsmWaitingForInput');Parent=[string]$_.Exception.Data['ParentOperationId']}}
        } $parent
        Check ($outcome.Threw) 'RESUME at the end of the input must stop with an exception, not return a status object (InputUnavailable used to become exit 3).'
        Check ($outcome.Type -ceq 'System.IO.EndOfStreamException' -and $outcome.Waiting -and $outcome.Parent -ceq $parent) 'The RESUME exception must be an EndOfStreamException with WsmWaitingForInput and the ParentOperationId.'
        # the entry maps exactly that exception to "Status=WaitingForInput ParentOperationId=<id>" and exit 2 (Test-CliWaitingForInput covers the mapping itself).
        # a typed answer other than RESUME and a blank answer keep their old meaning.
        $notResumed=& $module {param($parent)
            function script:Get-WsmWizardTargetRestoreResumePreview{param($Workspace,$PairId,$GeneralHostEvidence);[pscustomobject]@{Resumable=$true;PreviewCurrent=$true;ParentOperationId=$parent;PendingCount=2;ChallengeState='';PreviewHash=('a'*64)}}
            function script:Read-WsmWizardValue{param([string]$Label,[switch]$Optional);'NO'}
            $package=[pscustomobject]@{Manifest=[pscustomobject]@{PairId='pair-1'}}
            (Invoke-WsmWizardTargetRestoreResumeFlow 'work-root' 'state-dir' $package @() 6>$null).Status
        } $parent
        Check ($notResumed -ceq 'NotResumed') 'Another answer than RESUME must still return NotResumed.'
    }finally{Remove-Module WindowsServerMigration -Force -ErrorAction SilentlyContinue}
    Write-Host ('PASS: CLI return codes agree across entries (Operation/OperationRequest input errors 4, menu exit = worst typed-operation status, RESUME end-of-input 2, relative DeveloperProbe workspace) ('+$script:checks+' checks).')
}finally{
    $full=[IO.Path]::GetFullPath($root);$tmp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if($full.StartsWith($tmp,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $full -Leaf) -like 'wsm-cli-codes-*' -and [IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue}
}
