#requires -Version 5.1
# N6 (16.4-1)：CLI 在標準輸入結束而必填值仍缺少時，回「等待輸入」(exit 2) 並列出缺少欄位。
# 以真實 CLI 子行程驗證（標準輸入重新導向後關閉），涵蓋一般 action（DeliveryReceiptImport）與需要帳密的 action（NonCTransfer）。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$entry=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Start-ServerMigration.ps1'))
$engine=Join-Path $PSHOME 'powershell.exe';if(-not (Test-Path -LiteralPath $engine)){$engine=Join-Path $PSHOME 'pwsh.exe'}
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-cli-wait-'+[Guid]::NewGuid().ToString('N'))
$workspace=Join-Path $root 'manager'
[void][IO.Directory]::CreateDirectory($root)
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Invoke-Cli([string[]]$CliArguments,[string[]]$InputLines){
    $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$engine;$psi.UseShellExecute=$false;$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
    $psi.Arguments=(@('-NoProfile','-ExecutionPolicy','Bypass','-File','"'+$entry+'"')+$CliArguments) -join ' '
    $process=[Diagnostics.Process]::Start($psi)
    try{
        foreach($line in $InputLines){$process.StandardInput.WriteLine($line)}
        $process.StandardInput.Close()   # EndOfStream from here on
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(240000)){try{$process.Kill()}catch{};throw 'The CLI child process did not exit within 240 seconds.'}
        [pscustomobject]@{ExitCode=$process.ExitCode;Output=($stdout.Result+"`n"+$stderr.Result)}
    }finally{$process.Dispose()}
}
try{
    $init=Invoke-Cli @('-Action','Initialize','-Workspace',('"'+$workspace+'"')) @()
    Check ($init.ExitCode -eq 0) ('Initialize must return 0, got '+$init.ExitCode)
    $menu=@('-Action','Menu','-Workspace',('"'+$workspace+'"'))
    # Menu 22 -> role 4 (advanced operations) -> 2 (typed Core operation) -> role index (2 = Target, 3 = Manager) -> action id -> field prompts
    $prefix=@('22','4','2')
    $sentinel='N6-SENTINEL-'+[Guid]::NewGuid().ToString('N')

    # 1. general action: the first required field is typed, the second is missing when stdin ends.
    $general=Invoke-Cli $menu ($prefix+@('3','DeliveryReceiptImport',$sentinel))
    Check ($general.ExitCode -eq 2) ('General action at end of input must return 2 (waiting), got '+$general.ExitCode+"`n"+$general.Output)
    Check ($general.Output -match 'Status=WaitingForInput' -and $general.Output -match 'MissingFields=ExpectedHash') ('General action must list the missing ExpectedHash field.'+"`n"+$general.Output)
    Check ($general.Output -notmatch 'MissingFields=[^\r\n]*\bPath\b') 'The already typed Path must not be listed as missing.'
    # R26-1f：exit 2 的輸出要補一行下一步。缺欄位 -> 補齊後重跑。
    Check ($general.Output -match '(?m)^NextStep=[^\r\n]*補齊[^\r\n]*MissingFields') ('A waiting result must name its next step.'+"`n"+$general.Output)

    # 2. general action, nothing typed after the action id: all required fields are listed.
    $none=Invoke-Cli $menu ($prefix+@('3','DeliveryReceiptImport'))
    Check ($none.ExitCode -eq 2 -and $none.Output -match 'MissingFields=Path,ExpectedHash') ('Both required fields must be listed when none was typed.'+"`n"+$none.Output)

    # 3. credential action: required text fields are typed, stdin ends before the rest.
    $credEarly=Invoke-Cli $menu ($prefix+@('2','NonCTransfer',$sentinel,'second-value'))
    Check ($credEarly.ExitCode -eq 2) ('Credential action at end of input must return 2, got '+$credEarly.ExitCode+"`n"+$credEarly.Output)
    Check ($credEarly.Output -match 'MissingFields=SealedPlanPath,SealedPlanHash,ManifestPath,ManifestHash,FreezeEvidencePath,FreezeEvidenceHash,JournalPath,ResultPath') ('The credential action must list every remaining required field.'+"`n"+$credEarly.Output)

    # 4. credential action: every text field is supplied; the credential itself is never read from redirected stdin.
    $values=@(1..10|ForEach-Object{'value-'+$_})
    $credBlocked=Invoke-Cli $menu ($prefix+@('2','NonCTransfer')+$values+@('typed-password-must-not-be-read'))
    Check ($credBlocked.ExitCode -eq 2) ('A missing credential must return 2, got '+$credBlocked.ExitCode+"`n"+$credBlocked.Output)
    Check ($credBlocked.Output -match 'MissingFields=Credential,SourceCredential,TargetCredential') ('The missing credential fields must be listed.'+"`n"+$credBlocked.Output)
    Check ($credBlocked.Output -notmatch 'MissingFields=[^\r\n]*typed-password') 'The credential line must not be consumed as a value.'
    Check ($credBlocked.Output -match '(?m)^NextStep=[^\r\n]*互動主控台[^\r\n]*HTML') ('A blocked credential must point to the interactive console or the HTML credential dialog.'+"`n"+$credBlocked.Output)

    # 5. nothing typed before the end of input may be persisted (the secret field was missing).
    $leaks=@(Get-ChildItem -LiteralPath $root -Recurse -File -Force|Where-Object{[IO.File]::ReadAllText($_.FullName) -match 'N6-SENTINEL-|value-\d+|typed-password-must-not-be-read'})
    Check ($leaks.Count -eq 0) ('Values typed before the end of input were written to disk: '+(@($leaks|ForEach-Object Name) -join ', '))

    # 6. end of input where no required value is pending keeps its meaning (3), and -NonInteractive Menu has no input channel at all (waiting, never a plain failure).
    $idle=Invoke-Cli $menu @()
    Check ($idle.ExitCode -eq 3) ('End of input at the top menu must stay 3, got '+$idle.ExitCode)
    $niArgs=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File','"'+$entry+'"','-Action','Menu','-Workspace','"'+$workspace+'"')
    $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$engine;$psi.UseShellExecute=$false;$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true;$psi.Arguments=$niArgs -join ' '
    $p=[Diagnostics.Process]::Start($psi);try{$p.StandardInput.Close();$o=$p.StandardOutput.ReadToEndAsync();$e=$p.StandardError.ReadToEndAsync();[void]$p.WaitForExit(120000);$niCode=$p.ExitCode;$niOut=$o.Result+$e.Result}finally{$p.Dispose()}
    Check ($niCode -eq 2 -and $niOut -match 'MissingFields=') ('-NonInteractive Menu must report waiting (2) with its missing field, got '+$niCode+"`n"+$niOut)
    # R26-1f：RESUME／TAKEOVER 的下一步文字由入口的 Get-WaitingNextStepLine 決定（有 ParentOperationId 的等待 = 續作父作業）。
    $entryAst=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$null,[ref]$null)
    $helper=$entryAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-WaitingNextStepLine'},$true)
    Check ($null -ne $helper) 'The entry script must define Get-WaitingNextStepLine.'
    . ([scriptblock]::Create($helper.Extent.Text))
    $parentId='11111111-2222-3333-4444-555555555555'
    $resume=New-Object IO.EndOfStreamException('waiting for RESUME');$resume.Data['WsmWaitingForInput']=$true;$resume.Data['ParentOperationId']=$parentId
    $resumeLine=[string](Get-WaitingNextStepLine $resume)
    Check ($resumeLine -match '^NextStep=RESUME ' -and $resumeLine.Contains($parentId) -and $resumeLine -match 'TAKEOVER') ('A waiting parent must name RESUME with the parent id and the TAKEOVER alternative: '+$resumeLine)
    $fields=New-Object IO.EndOfStreamException('Console input ended');$fields.Data['WsmWaitingForInput']=$true;$fields.Data['WsmMissingFields']='Path,ExpectedHash'
    $fieldsLine=[string](Get-WaitingNextStepLine $fields)
    Check ($fieldsLine -match '^NextStep=' -and $fieldsLine -notmatch 'RESUME|TAKEOVER') ('Missing fields must not suggest RESUME or TAKEOVER: '+$fieldsLine)
    Check ($fieldsLine -notmatch '[\r\n]') 'The next step is one line.'
    Write-Host ('PASS: CLI end-of-input returns 2 with the missing fields for a general action and a credential action; credentials are never read from stdin, nothing typed is persisted ('+$checks+' checks).')
}finally{
    $full=[IO.Path]::GetFullPath($root);$tmp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if($full.StartsWith($tmp,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $full -Leaf) -like 'wsm-cli-wait-*' -and [IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
