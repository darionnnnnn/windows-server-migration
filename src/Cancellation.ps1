function Assert-WsmCancellationUtc([string]$Value,[string]$Description) {
    $parsed=[DateTimeOffset]::MinValue
    if(-not $Value -or $Value -notmatch 'Z$' -or -not [DateTimeOffset]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -or $parsed.Offset -ne [TimeSpan]::Zero){throw ($Description+' must be an exact UTC timestamp.')}
    $parsed
}
function ConvertTo-WsmCancellationTokenObject($Token) {
    if($Token -is [string]){try{$Token=ConvertFrom-WsmJson $Token}catch{throw 'Cancellation token JSON is invalid.'}}
    if(-not $Token){throw 'Cancellation token is missing its typed envelope.'};$kindProperty=$Token.PSObject.Properties['Kind'];if(-not $kindProperty -or [string]$kindProperty.Value -cne 'CancellationToken' -or -not $Token.PSObject.Properties['SchemaVersion']){throw 'Cancellation token is missing its typed envelope.'}
    $allowed=@('SchemaVersion','Kind','PairId','PlanHash','ManifestHash','OperationId','StateDirectory','RequestPath','CreatedUtc');$actual=@($Token.PSObject.Properties.Name);if(@($actual|Where-Object {$_ -notin $allowed}).Count -or @($allowed|Where-Object {$_ -notin $actual}).Count){throw 'Cancellation token has unknown or missing fields.'}
    if(($Token.SchemaVersion -isnot [int] -and $Token.SchemaVersion -isnot [long]) -or $Token.SchemaVersion -ne 1){throw 'Cancellation token schema is unsupported.'}
    if($Token.Kind -isnot [string]){throw 'Cancellation token kind has the wrong type.'}
    foreach($field in @('PairId','PlanHash','ManifestHash','OperationId','StateDirectory','RequestPath','CreatedUtc')){if($Token.PSObject.Properties[$field].Value -isnot [string]){throw ('Cancellation token field has the wrong type: '+$field+'.')}}
    Assert-WsmId ([string]$Token.PairId);Assert-WsmId ([string]$Token.OperationId)
    if([string]$Token.PlanHash -notmatch '^[a-fA-F0-9]{64}$' -or ([string]$Token.ManifestHash -and [string]$Token.ManifestHash -notmatch '^[a-fA-F0-9]{64}$')){throw 'Cancellation token has an invalid plan or manifest hash.'}
    if(-not [IO.Path]::IsPathRooted([string]$Token.StateDirectory)){throw 'Cancellation token state directory must be absolute.'};[void](Assert-WsmCancellationUtc ([string]$Token.CreatedUtc) 'Cancellation token creation time')
    $root=[IO.Path]::GetFullPath([string]$Token.StateDirectory).TrimEnd('\');if(-not $root){throw 'Cancellation token state directory is invalid.'}
    $expected=[IO.Path]::GetFullPath((Join-Path (Join-Path $root ([string]$Token.PairId)) ('cancel-'+[string]$Token.OperationId+'.json')))
    if([IO.Path]::GetFullPath([string]$Token.RequestPath) -ine $expected){throw 'Cancellation token request path is not the fixed pair/operation marker path.'}
    [pscustomobject]@{PairId=[string]$Token.PairId;PlanHash=([string]$Token.PlanHash).ToLowerInvariant();ManifestHash=([string]$Token.ManifestHash).ToLowerInvariant();OperationId=[string]$Token.OperationId;StateDirectory=$root;RequestPath=$expected;CreatedUtc=[string]$Token.CreatedUtc;Kind='CancellationToken';SchemaVersion=1}
}
function New-WsmCancellationToken([string]$PairId,[string]$PlanHash,[string]$ManifestHash,[string]$OperationId,[string]$StateDirectory) {
    Assert-WsmId $PairId;Assert-WsmId $OperationId
    if($PlanHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'Cancellation token requires the exact approved plan SHA256.'}
    if($ManifestHash -and $ManifestHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'Cancellation token manifest SHA256 is invalid.'}
    if(-not [IO.Path]::IsPathRooted($StateDirectory)){throw 'Cancellation token state directory must be absolute.'}
    $root=[IO.Path]::GetFullPath($StateDirectory).TrimEnd('\');if(-not $root){throw 'Cancellation token state directory is invalid.'}
    $path=[IO.Path]::GetFullPath((Join-Path (Join-Path $root $PairId) ('cancel-'+$OperationId+'.json')))
    [pscustomobject]@{SchemaVersion=1;Kind='CancellationToken';PairId=$PairId;PlanHash=$PlanHash.ToLowerInvariant();ManifestHash=$ManifestHash.ToLowerInvariant();OperationId=$OperationId;StateDirectory=$root;RequestPath=$path;CreatedUtc=(Get-WsmUtc)}
}
function Assert-WsmCancellationTokenBinding($Token,[string]$PairId,[string]$PlanHash,[string]$ManifestHash,[string]$StateDirectory) {
    $t=ConvertTo-WsmCancellationTokenObject $Token;Assert-WsmId $PairId
    if($t.PairId -cne $PairId -or $t.PlanHash -ine $PlanHash -or $t.ManifestHash -ine $ManifestHash -or $t.StateDirectory -ine [IO.Path]::GetFullPath($StateDirectory).TrimEnd('\')){throw 'Cancellation token is not bound to this pair, plan, manifest and state directory.'}
    $t
}
function Assert-WsmCancellationRequest($Request,$Token) {
    if(-not $Request){throw 'Cancellation marker is empty.'}
    $allowed=@('SchemaVersion','Kind','PairId','PlanHash','ManifestHash','OperationId','StateDirectory','Owner','Evidence','RequestedUtc');$actual=@($Request.PSObject.Properties.Name);if(@($actual|Where-Object {$_ -notin $allowed}).Count -or @($allowed|Where-Object {$_ -notin $actual}).Count){throw 'Cancellation marker has unknown or missing fields.'}
    if(($Request.SchemaVersion -isnot [int] -and $Request.SchemaVersion -isnot [long]) -or $Request.SchemaVersion -ne 1 -or $Request.Kind -isnot [string] -or $Request.Kind -cne 'CancellationRequest'){throw 'Cancellation marker has an unsupported schema.'}
    foreach($field in @('PairId','PlanHash','ManifestHash','OperationId','StateDirectory','Owner','Evidence','RequestedUtc')){if($Request.PSObject.Properties[$field].Value -isnot [string]){throw ('Cancellation marker field has the wrong type: '+$field+'.')}}
    foreach($field in @('PairId','PlanHash','ManifestHash','OperationId','StateDirectory')){if([string]$Request.$field -ine [string]$Token.$field){throw 'Cancellation marker scope mismatch; reject it and retain for review.'}}
    if([string]::IsNullOrWhiteSpace($Request.Owner) -or $Request.Owner.Length -gt 256 -or $Request.Owner -match '[\x00-\x1f]' -or [string]::IsNullOrWhiteSpace($Request.Evidence) -or $Request.Evidence.Length -gt 2048 -or $Request.Evidence -match '[\x00-\x1f]'){throw 'Cancellation marker lacks valid owner or evidence.'}
    [void](Assert-WsmCancellationUtc $Request.RequestedUtc 'Cancellation marker request time')
}
function Assert-WsmCancellationDirectoryProtection([string]$Path) {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$expected=@($identity.User.Value,'S-1-5-18','S-1-5-32-544' | Select-Object -Unique)
    try{$acl=Get-Acl -LiteralPath ([IO.Path]::GetFullPath($Path)) -ErrorAction Stop}catch{throw 'Cannot read the existing cancellation operation directory owner and DACL; refusing to write a request.'}
    if(-not $acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $identity.User.Value){throw 'Existing cancellation operation directory is not protected for the current owner.'}
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]));$seen=@{}
    foreach($rule in $rules){$sid=$rule.IdentityReference.Value;if($rule.IsInherited -or $sid -notin $expected -or $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or (($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl) -or $rule.InheritanceFlags -ne ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit) -or $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None){throw 'Existing cancellation operation directory DACL differs from the protected owner/SYSTEM/Administrators policy.'};$seen[$sid]=$true}
    if($seen.Count -ne $expected.Count -or @($expected|Where-Object {-not $seen.ContainsKey($_)}).Count){throw 'Existing cancellation operation directory DACL is missing an authorized owner/SYSTEM/Administrators grant.'}
}
function Request-WsmCancellation($Token,[string]$Owner,[string]$Evidence) {
    $t=ConvertTo-WsmCancellationTokenObject $Token
    if([string]::IsNullOrWhiteSpace($Owner) -or $Owner.Length -gt 256 -or $Owner -match '[\x00-\x1f]' -or [string]::IsNullOrWhiteSpace($Evidence) -or $Evidence.Length -gt 2048 -or $Evidence -match '[\x00-\x1f]'){throw 'Cancellation requires bounded owner and evidence text.'}
    if(-not [IO.Directory]::Exists($t.StateDirectory)){throw 'Cancellation state directory does not exist.'};Assert-WsmNoReparse $t.StateDirectory
    $pairRoot=Join-Path $t.StateDirectory $t.PairId
    $lockPath=Join-Path $t.StateDirectory ('cancel-'+$t.PairId+'-'+$t.OperationId+'.lock');Assert-WsmNoReparse $lockPath;$markerLock=$null;$wait=[Diagnostics.Stopwatch]::StartNew()
    while(-not $markerLock){try{$markerLock=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')}catch [IO.IOException]{if($wait.Elapsed.TotalSeconds -ge 5){throw 'Timed out waiting for this operation''s cancellation marker lock.'};Start-Sleep -Milliseconds 25}}
    try {
        if(-not [IO.Directory]::Exists($pairRoot)){[void][IO.Directory]::CreateDirectory($pairRoot);$protect=Get-Command Protect-WsmDirectory -ErrorAction SilentlyContinue;if(-not $protect){throw 'Cannot create cancellation marker without the protected operation-directory helper.'};Protect-WsmDirectory $pairRoot}else{Assert-WsmCancellationDirectoryProtection $pairRoot}
        Assert-WsmNoReparse $pairRoot
        if([IO.File]::Exists($t.RequestPath)){
            Assert-WsmNoReparse $t.RequestPath;$existing=Read-WsmJson $t.RequestPath;Assert-WsmCancellationRequest $existing $t
            if($existing.Owner -cne $Owner -or $existing.Evidence -cne $Evidence){throw 'Conflicting cancellation request exists; original owner/evidence/time were retained.'}
            return [pscustomobject]@{Requested=$true;AlreadyRequested=$true;OperationId=$t.OperationId;RequestPath=$t.RequestPath;RequestedUtc=$existing.RequestedUtc;Owner=$existing.Owner;Evidence=$existing.Evidence}
        }
        $request=[pscustomobject][ordered]@{SchemaVersion=1;Kind='CancellationRequest';PairId=$t.PairId;PlanHash=$t.PlanHash;ManifestHash=$t.ManifestHash;OperationId=$t.OperationId;StateDirectory=$t.StateDirectory;Owner=$Owner;Evidence=$Evidence;RequestedUtc=(Get-WsmUtc)}
        Write-WsmJson $t.RequestPath $request
        [pscustomobject]@{Requested=$true;AlreadyRequested=$false;OperationId=$t.OperationId;RequestPath=$t.RequestPath;RequestedUtc=$request.RequestedUtc;Owner=$Owner;Evidence=$Evidence}
    } finally {$markerLock.Dispose()}
}
function Test-WsmCancellationRequested($Token) {
    $t=ConvertTo-WsmCancellationTokenObject $Token
    if(-not [IO.File]::Exists($t.RequestPath)){return $false}
    Assert-WsmNoReparse $t.StateDirectory;Assert-WsmNoReparse (Join-Path $t.StateDirectory $t.PairId);Assert-WsmNoReparse $t.RequestPath
    $request=Read-WsmJson $t.RequestPath;Assert-WsmCancellationRequest $request $t
    $true
}
function Assert-WsmCancellationBoundary($Token,[string]$Phase) {
    if(-not $Token){return}
    $t=ConvertTo-WsmCancellationTokenObject $Token
    if(-not (Test-WsmCancellationRequested $t)){return}
    $error=New-Object OperationCanceledException('Owner-requested cancellation observed at durable boundary; preserve current effects and reconcile before retry.')
    $error.Data['CancellationRequested']=$true;$error.Data['CancellationBoundary']=$Phase;$error.Data['PairId']=$t.PairId;$error.Data['PlanHash']=$t.PlanHash;$error.Data['ManifestHash']=$t.ManifestHash;$error.Data['OperationId']=$t.OperationId;$error.Data['NativeResult']='Cancelled';$error.Data['AutomaticRetrySafe']=$false
    throw $error
}
function Get-WsmOperationProgressPath($Token) {
    $t=ConvertTo-WsmCancellationTokenObject $Token
    Join-Path (Join-Path $t.StateDirectory $t.PairId) ('progress-'+$t.OperationId+'.json')
}
function Set-WsmOperationProgress($Token,[string]$Phase,[long]$CompletedBytes,[long]$TotalBytes,[long]$ElapsedSeconds,[string]$LastActivityUtc) {
    if(-not $Token){return $false}
    if($Phase -notmatch '^[A-Za-z][A-Za-z0-9_.-]{0,63}$' -or $CompletedBytes -lt 0 -or $TotalBytes -lt 0 -or $ElapsedSeconds -lt 0){throw 'Operation progress fields are outside their bounded contract.'}
    [void](Assert-WsmCancellationUtc $LastActivityUtc 'Operation progress last-activity time')
    $t=ConvertTo-WsmCancellationTokenObject $Token;$directory=Join-Path $t.StateDirectory $t.PairId
    if(-not [IO.Directory]::Exists($directory)){return $false}
    Assert-WsmNoReparse $directory;$path=Get-WsmOperationProgressPath $t;Assert-WsmNoReparse $path
    $key=$t.PairId+'/'+$t.OperationId;$now=[DateTime]::UtcNow
    if(-not (Get-Variable -Name WsmProgressLastWriteUtc -Scope Script -ErrorAction SilentlyContinue)){$script:WsmProgressLastWriteUtc=@{}}
    if($script:WsmProgressLastWriteUtc.ContainsKey($key) -and ($now-$script:WsmProgressLastWriteUtc[$key]).TotalMilliseconds -lt 1000){return $false}
    $row=[pscustomobject][ordered]@{SchemaVersion=1;Kind='OperationProgress';PairId=$t.PairId;OperationId=$t.OperationId;Phase=$Phase;CompletedBytes=$CompletedBytes;TotalBytes=$TotalBytes;ElapsedSeconds=$ElapsedSeconds;LastActivityUtc=$LastActivityUtc;UpdatedUtc=$now.ToString('yyyy-MM-ddTHH:mm:ss.fffZ',[Globalization.CultureInfo]::InvariantCulture)}
    if([Text.Encoding]::UTF8.GetByteCount(($row | ConvertTo-Json -Depth 4 -Compress)) -gt 4096){throw 'Operation progress record exceeds its fixed 4 KiB bound.'}
    Write-WsmJson $path $row;$script:WsmProgressLastWriteUtc[$key]=$now
    $status=$Phase;if($TotalBytes -gt 0){$status+=' | '+$CompletedBytes.ToString([Globalization.CultureInfo]::InvariantCulture)+'/'+$TotalBytes.ToString([Globalization.CultureInfo]::InvariantCulture)+' bytes'}elseif($CompletedBytes -gt 0){$status+=' | '+$CompletedBytes.ToString([Globalization.CultureInfo]::InvariantCulture)+' bytes'};if($ElapsedSeconds -gt 0){$status+=' | '+$ElapsedSeconds.ToString([Globalization.CultureInfo]::InvariantCulture)+'s'};if($Phase -ceq 'NativeProcessWait'){$status+=' | last observed activity '+$LastActivityUtc};Write-Progress -Id 31 -Activity 'Migration operation progress' -Status $status;$true
}
function Clear-WsmOperationProgress($Token) {
    if(-not $Token){return}
    $t=ConvertTo-WsmCancellationTokenObject $Token;$directory=Join-Path $t.StateDirectory $t.PairId
    if(-not [IO.Directory]::Exists($directory)){return}
    Assert-WsmNoReparse $directory;$path=Get-WsmOperationProgressPath $t;Assert-WsmNoReparse $path
    if([IO.File]::Exists($path)){[IO.File]::Delete($path)}
    Write-Progress -Id 31 -Activity 'Migration operation progress' -Completed
}
function Get-WsmCancellableStreamHash($Stream,$CancellationToken=$null,[string]$Phase='HashBuffer') {
    $sha=[Security.Cryptography.SHA256]::Create();$buffer=New-Object byte[] 65536
    try {
        if(-not $CancellationToken){return [BitConverter]::ToString($sha.ComputeHash($Stream)).Replace('-','').ToLowerInvariant()}
        $watch=[Diagnostics.Stopwatch]::StartNew();$bytes=[long]0;$total=[long]0;if($Stream.CanSeek){try{$total=[Math]::Max([long]0,$Stream.Length-$Stream.Position)}catch{$total=0}};$lastActivity=Get-WsmUtc
        try { while($true){Assert-WsmCancellationBoundary $CancellationToken $Phase;$count=$Stream.Read($buffer,0,$buffer.Length);if($count -eq 0){break};[void]$sha.TransformBlock($buffer,0,$count,$buffer,0);$bytes+=$count;$lastActivity=Get-WsmUtc;if($watch.ElapsedMilliseconds -ge 1000){[void](Set-WsmOperationProgress $CancellationToken $Phase $bytes $total ([long]$watch.Elapsed.TotalSeconds) $lastActivity)} }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0),0,0)
        [BitConverter]::ToString($sha.Hash).Replace('-','').ToLowerInvariant()
        } finally {Clear-WsmOperationProgress $CancellationToken}
    } finally {$sha.Dispose()}
}
function Get-WsmCancellableFileHash([string]$Path,$CancellationToken=$null,[string]$Phase='FileHashBuffer') {
    Assert-WsmNoReparse $Path
    $stream=[IO.File]::Open([IO.Path]::GetFullPath($Path),'Open','Read','Read')
    try {Get-WsmCancellableStreamHash $stream $CancellationToken $Phase} finally {$stream.Dispose()}
}
function Copy-WsmCancellableStream($InputStream,$OutputStream,$CancellationToken=$null,[string]$Phase='CopyBuffer') {
    if(-not $CancellationToken){$InputStream.CopyTo($OutputStream);return}
    $buffer=New-Object byte[] 65536;$watch=[Diagnostics.Stopwatch]::StartNew();$bytes=[long]0;$total=[long]0;if($InputStream.CanSeek){try{$total=[Math]::Max([long]0,$InputStream.Length-$InputStream.Position)}catch{$total=0}};$lastActivity=Get-WsmUtc
    try { while($true){Assert-WsmCancellationBoundary $CancellationToken $Phase;$count=$InputStream.Read($buffer,0,$buffer.Length);if($count -eq 0){break};$OutputStream.Write($buffer,0,$count);$bytes+=$count;$lastActivity=Get-WsmUtc;if($watch.ElapsedMilliseconds -ge 1000){[void](Set-WsmOperationProgress $CancellationToken $Phase $bytes $total ([long]$watch.Elapsed.TotalSeconds) $lastActivity)} } }
    finally {Clear-WsmOperationProgress $CancellationToken}
}
function Get-WsmCancellationFailureDetails($Failure) {
    $error=$Failure;if($Failure -is [Management.Automation.ErrorRecord]){$error=$Failure.Exception};if($error -isnot [OperationCanceledException] -or -not $error.Data['CancellationRequested']){throw 'Cancellation failure details require an owner-requested OperationCanceledException.'}
    $hresult=$null;if($error.HResult -ne 0){$hresult=('0x{0:X8}' -f $error.HResult)}
    [pscustomobject]@{Category='Cancelled';ExitCode=3;OperationId=[string]$error.Data['OperationId'];PairId=[string]$error.Data['PairId'];PlanHash=[string]$error.Data['PlanHash'];ManifestHash=[string]$error.Data['ManifestHash'];Boundary=[string]$error.Data['CancellationBoundary'];NativeTool=[string]$error.Data['NativeTool'];NativeResult='Cancelled';NativeCode=$error.Data['NativeCode'];HResult=$hresult;Hint='Cancellation stopped at a durable boundary; inspect actual effects and reconcile before retry.';ProcessId=$error.Data['NativeProcessId'];ProcessKillAttempted=$error.Data['ProcessKillAttempted'];ProcessExitObserved=$error.Data['ProcessExitObserved'];ProcessKillVerified=$error.Data['ProcessKillVerified'];TerminationScope=[string]$error.Data['TerminationScope'];ChildProcessTerminationVerified=$error.Data['ChildProcessTerminationVerified'];AutomaticRetrySafe=$false;RawOutputIncluded=$false}
}
