#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
Add-Type -TypeDefinition @'
public class WsmHttpFixtureStream : System.IO.MemoryStream {
    public WsmHttpFixtureStream(byte[] data) : base(data) {}
    public WsmHttpFixtureStream() : base() {}
    public bool Slow; public override int ReadByte() { if(Slow) System.Threading.Thread.Sleep(8); return base.ReadByte(); }
    public override bool CanTimeout { get { return true; } }
    public override int ReadTimeout { get; set; }
    public override int WriteTimeout { get; set; }
}
'@
& $module {
    $script:httpChecks=0
    function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:httpChecks++}
    function Reject([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action | Out-Null}catch{$failed=$true};Check $failed $Message}
    function Client([string]$Text){$stream=New-Object WsmHttpFixtureStream -ArgumentList (,[Text.Encoding]::UTF8.GetBytes($Text));$client=[pscustomobject]@{Stream=$stream};$client|Add-Member ScriptMethod GetStream {$this.Stream};$client}
    $request=Read-WsmLocalHttpRequest (Client "POST /api/operations HTTP/1.1`r`nHost: 127.0.0.1:1234`r`nContent-Length: 2`r`n`r`n{}")
    Check ($request.Method -ceq 'POST' -and $request.Body -ceq '{}' -and $request.Headers.host -ceq '127.0.0.1:1234') 'Native HTTP request parsing lost exact body or headers.'
    foreach($header in @(('Host: a'+"`r`n"+'Host: b'),'Transfer-Encoding: chunked','Content-Length: 1048577','Content-Length: -1','bad header')){Reject {Read-WsmLocalHttpRequest (Client ("GET / HTTP/1.1`r`n"+$header+"`r`n`r`n"))} 'Malformed HTTP input was accepted.'}
    Reject {Read-WsmLocalHttpRequest (Client "PUT / HTTP/1.1`r`n`r`n")} 'Unsupported HTTP verb was accepted.'
    Reject {Read-WsmLocalHttpRequest (Client "POST / HTTP/1.1`r`nContent-Length: 3`r`n`r`nx")} 'Truncated HTTP body was accepted.'
    Reject {Read-WsmLocalHttpRequest (Client ("GET / HTTP/1.1`r`nX: "+('a'*8192)+"`r`n`r`n"))} 'Oversized headers were accepted.'
    $slow=Client "GET / HTTP/1.1`r`n`r`n";$slow.Stream.Slow=$true;Reject {Read-WsmLocalHttpRequest $slow -MaximumRequestMilliseconds 10} 'Slow-trickle request exceeded the aggregate deadline without rejection.'
    $client=[pscustomobject]@{Stream=(New-Object WsmHttpFixtureStream)};$client|Add-Member ScriptMethod GetStream {$this.Stream}
    $body=[Text.Encoding]::UTF8.GetBytes(('完整內容'*5000));Write-WsmLocalHttpResponse $client 200 'text/html; charset=utf-8' $body
    $actual=$client.Stream.ToArray();$text=[Text.Encoding]::UTF8.GetString($actual);$boundary=$text.IndexOf("`r`n`r`n");$header=$text.Substring(0,$boundary)
    Check ($header.Contains('Content-Length: '+$body.Length) -and $text.Substring($boundary+4) -ceq [Text.Encoding]::UTF8.GetString($body)) 'Native response writer truncated UTF-8 content or used character length.'
    Check ($header.Contains("script-src 'self'") -and -not $header.Contains('unsafe-inline') -and -not $header.Contains('adguard')) 'Native security headers differ from the declared policy.'
    $actions=@(Get-WsmHtmlActionMetadata Manager)
    $submit=@($actions | Where-Object action -CEQ WindowsSettingsSubmit)[0]
    Check (@($submit.parameters | Where-Object name -CEQ ExpectedRevision).Count -eq 1 -and @($submit.parameters | Where-Object name -CEQ Decisions)[0].allowEmpty) 'Settings preview revision or legitimate empty decisions are hidden by native metadata.'
    $hash1=Get-WsmHtmlRequestHash 'C:\fixture' 'pair-one' 'Manager' 'CheckToolRelease' ([pscustomobject]@{Path='C:\release'}) 0
    $hash2=Get-WsmHtmlRequestHash 'C:\fixture' 'pair-two' 'Manager' 'CheckToolRelease' ([pscustomobject]@{Path='C:\release'}) 0
    Check ($hash1 -cne $hash2 -and $hash1 -ceq (Get-WsmHtmlRequestHash 'C:\fixture' 'pair-one' 'Manager' 'CheckToolRelease' ([pscustomobject]@{Path='C:\release'}) 0)) 'Durable idempotency hash lost the current pair scope or cannot survive reconnection.'
    Check ($actions.Count -gt 90) 'HTML actions do not expose the native operation surface.'
    Check (-not @($actions | Where-Object {$_.parameters | Where-Object name -EQ CancellationToken}).Count) 'Cancellation capability was exposed as editable input.'
    $probe=Get-Command Export-WsmAssistiveHttpProbe
    Check (-not @($actions | Where-Object {$_.parameters | Where-Object name -EQ RequestAdapter}).Count) 'Internal probe script adapter appeared in browser forms.'
    Reject {ConvertTo-WsmHtmlArguments $probe ([pscustomobject]@{Origin='http://127.0.0.1:1234';OutputPath='C:\fixture.json';RequestAdapter='throw injected'})} 'Internal script adapter accepted through HTML.'
    $command=Get-Command Set-WsmAssistiveSoftwareVersion
    $args=ConvertTo-WsmHtmlArguments $command ([pscustomobject]@{Workspace='C:\fixture';PairId=[Guid]::NewGuid().ToString();SoftwareId=('a'*64);ChosenVersion='new; $(invalid)';Reason='owner selected';ExpectedRevision=1})
    Check ($args.ChosenVersion -ceq 'new; $(invalid)' -and $args.ExpectedRevision -eq 1) 'Typed arguments interpreted source text as commands.'
    Reject {ConvertTo-WsmHtmlArguments $command ([pscustomobject]@{Unknown='anything'})} 'Unknown action arguments were accepted.'
    $outputs=@(Get-WsmHtmlResultProjection @([pscustomobject]@{Status='ReviewRequired';Path='C:\report.html';Secrets='sentinel';Password='sentinel';Xml='<secret/>'}))
    Check ($outputs.Count -eq 1 -and $outputs[0].Status -ceq 'ReviewRequired' -and ($outputs|ConvertTo-Json) -notmatch 'sentinel|<secret') 'Durable job outputs included configuration or secrets.'
    $historyRoot=Join-Path ([IO.Path]::GetTempPath()) ('wsm-http-history-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($historyRoot)
    try{
        $id=[Guid]::NewGuid().ToString();$key=[Guid]::NewGuid().ToString();$recordPath=Join-Path $historyRoot ($id+'.json')
        Write-WsmJson $recordPath ([pscustomobject]@{jobId=$id;idempotencyKey=$key;RequestHash=('a'*64);status='Running';canCancel=$true})
        $jobs=@{};$keys=@{};Import-WsmHtmlJobHistory $historyRoot $jobs $keys
        Check ($keys.ContainsKey($key) -and $keys[$key].Id -ceq $id -and $keys[$key].Hash -ceq ('a'*64)) 'Restart lost the durable idempotency binding.'
        Check ($jobs[$id].Record.status -ceq 'Interrupted' -and -not $jobs[$id].Record.canCancel -and (Read-WsmJson $recordPath).status -ceq 'Interrupted') 'Restart promoted an unfinished worker or exposed a stale cancellation handle.'
    }finally{if([IO.Directory]::Exists($historyRoot)){Remove-Item -LiteralPath $historyRoot -Recurse -Force}}
    Write-Host ('PASS: '+$script:httpChecks+' native HTTP parser/writer and typed action checks; live browser transport is independently probed.')
}
