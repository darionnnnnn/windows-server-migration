#requires -Version 5.1
# N9c / D1 / R7-07: environment variables and relative paths resolve only from the Source resolution
# context stored in the inventory (machine layer + ProfileList). Never from the process that happens
# to run the resolver (Manager, Target, or a restarted Manager).
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$manifest=Join-Path $repo 'src\WindowsServerMigration.psd1'
$module=Import-Module $manifest -Force -PassThru -DisableNameChecking 3>$null
$script:Checks=0
function Check($Condition,[string]$Message){if(-not $Condition){throw ('FAIL: '+$Message)};$script:Checks++}
$work=Join-Path ([IO.Path]::GetTempPath()) ('wsm-n9c-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$appRoot=Join-Path $work 'SourceApps';[void][IO.Directory]::CreateDirectory((Join-Path $appRoot 'site'));[void][IO.Directory]::CreateDirectory((Join-Path $appRoot 'web'))
[IO.File]::WriteAllText((Join-Path $appRoot 'site\web.config'),'<configuration><appSettings /></configuration>')
$sourceFile=Join-Path $repo 'src\SoftwareInventory.ps1'
$envNames=@('WSM_N9C_APP','USERPROFILE','APPDATA','LOCALAPPDATA','SystemDrive','TEMP')
$savedEnv=@{};foreach($n in $envNames){$savedEnv[$n]=[Environment]::GetEnvironmentVariable($n,'Process')}
try {
    # Build the Source-side context through the real builder with mocked Source facts.
    $builder={
        param($AppRoot)
        function Get-WsmMachineEnvironment { @{ 'Path'='C:\Windows\system32;C:\Windows'; 'TEMP'='C:\Windows\TEMP'; 'WSM_N9C_APP'=$AppRoot; 'WSM_N9C_SECRET_TOKEN'='must-not-be-stored'; 'WSM_N9C_PROFILEHOME'='%SystemDrive%\Users' } }
        function Get-WsmResolutionSystemEnvironment { [ordered]@{ SystemRoot='C:\Windows'; windir='C:\Windows'; SystemDrive='C:'; ProgramData='C:\ProgramData'; ProgramFiles='C:\Program Files' } }
        function Get-WsmResolutionProfileList { [pscustomobject]@{Status='Success';Map=[ordered]@{ 'S-1-5-18'='%systemroot%\system32\config\systemprofile'; 'S-1-5-21-1-2-3-1001'='%SystemDrive%\Users\svcuser' }} }
        function Resolve-WsmAccountToSid([string]$Account) { switch ($Account) { '.\svcuser' {'S-1-5-21-1-2-3-1001'} 'CONTOSO\noprofile' {'S-1-5-21-1-2-3-1002'} default {$null} } }
        $items=@(
            (New-WsmItem '11111111-2222-3333-4444-555555555555' Services Service 'svc' 'svc' @{StartName='.\svcuser'}),
            (New-WsmItem '11111111-2222-3333-4444-555555555555' Services Service 'sys' 'sys' @{StartName='LocalSystem'}),
            (New-WsmItem '11111111-2222-3333-4444-555555555555' Services Service 'ghost' 'ghost' @{StartName='CONTOSO\ghost'}),
            (New-WsmItem '11111111-2222-3333-4444-555555555555' Services Service 'np' 'np' @{StartName='CONTOSO\noprofile'}),
            (New-WsmItem '11111111-2222-3333-4444-555555555555' Tasks ScheduledTask '\T1' '\T1' @{Xml='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal id="A"><UserId>S-1-5-21-1-2-3-1001</UserId></Principal></Principals><Actions><Exec><Command>%USERPROFILE%\bin\tool.exe</Command></Exec></Actions></Task>'})
        )
        Get-WsmSourceResolutionContext '11111111-2222-3333-4444-555555555555' $items
    }
    $ctx=& $module $builder $appRoot
    Check ($ctx.Kind -ceq 'SourceResolutionContext' -and $ctx.HostId -ceq '11111111-2222-3333-4444-555555555555' -and $ctx.SchemaVersion -eq 1) 'Context identity fields missing.'
    Check ([DateTime]::Parse($ctx.ObservedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).Kind -eq [DateTimeKind]::Utc) 'ObservedUtc is not UTC.'
    Check (@($ctx.MachineEnvironment | Where-Object Name -CEQ 'WSM_N9C_APP').Count -eq 1 -and @($ctx.MachineEnvironment | Where-Object Name -CEQ 'SystemRoot').Count -eq 1) 'Machine layer variables were not captured.'
    Check (@($ctx.MachineEnvironment | Where-Object Name -Like '*SECRET*').Count -eq 0 -and $ctx.ExcludedEnvironmentNames -contains 'WSM_N9C_SECRET_TOKEN' -and ($ctx | ConvertTo-Json -Depth 8) -notmatch 'must-not-be-stored') 'Secret-looking machine variable was stored in the inventory context.'
    $svc=@($ctx.Accounts | Where-Object Account -EQ '.\svcuser')[0]
    Check ($svc.Sid -ceq 'S-1-5-21-1-2-3-1001' -and $svc.SidStatus -ceq 'Resolved' -and $svc.ProfileStatus -ceq 'Found' -and $svc.ProfileImagePath -ceq '%SystemDrive%\Users\svcuser' -and $svc.Sources -contains 'Service') 'Service account SID/profile mapping missing.'
    Check (@($ctx.Accounts | Where-Object {$_.Account -eq 'S-1-5-21-1-2-3-1001'})[0].Sources -contains 'ScheduledTask') 'Task principal was not mapped.'
    $ghost=@($ctx.Accounts | Where-Object Account -EQ 'CONTOSO\ghost')[0]
    Check ($null -eq $ghost.Sid -and $ghost.SidStatus -ceq 'Unresolved') 'Unresolvable account SID was not marked.'
    $np=@($ctx.Accounts | Where-Object Account -EQ 'CONTOSO\noprofile')[0]
    Check ($np.Sid -and $np.ProfileStatus -ceq 'NoProfile' -and $null -eq $np.ProfileImagePath) 'Account without profile was not marked.'
    Check (@($ctx.Accounts | Where-Object Account -EQ 'LocalSystem')[0].Sid -ceq 'S-1-5-18') 'LocalSystem well-known SID missing.'

    # The context survives a JSON round trip and its hash is stable (it is bound into the inventory projection).
    $json=$ctx | ConvertTo-Json -Depth 10
    $reloaded=$json | ConvertFrom-Json
    $hashA=& $module { param($c) Get-WsmSourceResolutionContextHash $c } $ctx
    $hashB=& $module { param($c) Get-WsmSourceResolutionContextHash $c } $reloaded
    Check ($hashA -match '^[a-f0-9]{64}$' -and $hashA -ceq $hashB) 'Context hash is not stable across a JSON round trip.'

    # Resolution cases, with Manager/Target-like process environment deliberately different.
    [Environment]::SetEnvironmentVariable('WSM_N9C_APP','M:\ManagerOnly','Process')
    [Environment]::SetEnvironmentVariable('USERPROFILE','M:\Users\manager','Process')
    [Environment]::SetEnvironmentVariable('APPDATA','M:\Users\manager\AppData\Roaming','Process')
    [Environment]::SetEnvironmentVariable('LOCALAPPDATA','M:\Users\manager\AppData\Local','Process')
    [Environment]::SetEnvironmentVariable('SystemDrive','M:','Process')
    $svcSid='S-1-5-21-1-2-3-1001';$noProfileSid='S-1-5-21-1-2-3-1002'
    $resolve={param($c,$raw,$sid) Resolve-WsmSourcePath $raw $c $sid}
    $r=& $module $resolve $reloaded '%WSM_N9C_APP%\data\a.exe' $null
    Check ($r.Basis -ceq 'Machine' -and $r.Resolved -ceq ($appRoot+'\data\a.exe') -and $r.Raw -ceq '%WSM_N9C_APP%\data\a.exe' -and $r.Variables -contains 'WSM_N9C_APP') 'Machine variable did not resolve from the Source context (Manager environment leaked?).'
    $r=& $module $resolve $reloaded '%wsm_n9c_app%\x' $null
    Check ($r.Basis -ceq 'Machine' -and $r.Resolved -ceq ($appRoot+'\x')) 'Variable names must be case-insensitive.'
    $r=& $module $resolve $reloaded '%SystemDrive%\inetpub\wwwroot' $null
    Check ($r.Basis -ceq 'Machine' -and $r.Resolved -ceq 'C:\inetpub\wwwroot') 'SystemDrive must come from the Source machine layer, not the reviewing host.'
    $r=& $module $resolve $reloaded '%WSM_N9C_PROFILEHOME%\x' $null
    Check ($r.Basis -ceq 'Machine' -and $r.Resolved -ceq 'C:\Users\x') 'Nested machine variable did not resolve through the context.'
    $r=& $module $resolve $reloaded '%USERPROFILE%\docs' $svcSid
    Check ($r.Basis -ceq 'ProfileDerived' -and $r.Resolved -ceq 'C:\Users\svcuser\docs') 'USERPROFILE was not derived from the account ProfileImagePath.'
    $r=& $module $resolve $reloaded '%APPDATA%\v' $svcSid
    Check ($r.Basis -ceq 'ProfileDerived' -and $r.Resolved -ceq 'C:\Users\svcuser\AppData\Roaming\v') 'APPDATA derivation is wrong.'
    $r=& $module $resolve $reloaded '%LOCALAPPDATA%\v' $svcSid
    Check ($r.Basis -ceq 'ProfileDerived' -and $r.Resolved -ceq 'C:\Users\svcuser\AppData\Local\v') 'LOCALAPPDATA derivation is wrong.'
    $r=& $module $resolve $reloaded '%USERPROFILE%\docs' 'S-1-5-18'
    Check ($r.Basis -ceq 'ProfileDerived' -and $r.Resolved -ceq 'C:\Windows\system32\config\systemprofile\docs') 'LocalSystem profile derivation is wrong.'
    $r=& $module $resolve $reloaded '%UserProfile%\docs' $svcSid
    Check ($r.Resolved -ceq 'C:\Users\svcuser\docs') 'Profile variable names must be case-insensitive.'
    foreach($case in @(
        @('%CUSTOM_USER_VAR%\x',$svcSid,'custom variable'),
        @('%HOMEPATH%\x',$svcSid,'folder-redirection style variable'),
        @('%OneDrive%\x',$svcSid,'OneDrive redirection variable'),
        @('data\relative.txt',$null,'relative path'),
        @('.\relative.txt',$null,'dot relative path'),
        @('C:\app\..\other',$null,'parent segment'),
        @('..\other',$null,'leading parent segment'),
        @('%USERPROFILE%\x',$noProfileSid,'account without profile'),
        @('%USERPROFILE%\x',$null,'no account'),
        @('%APPDATA%\x','S-1-5-21-9-9-9-9','unknown SID'),
        @('%TEMP%\x',$svcSid,'user scoped TEMP for a real user account'),
        @('%WSM_N9C_SECRET_TOKEN%\x',$null,'excluded secret-looking variable'),
        @('%WSM_N9C_APP%\..\x',$null,'machine variable followed by parent segment'),
        @('',$null,'empty')
    )){
        $r=& $module $resolve $reloaded $case[0] $case[1]
        Check ($r.Basis -ceq 'Unresolved' -and $null -eq $r.Resolved -and $r.Raw -ceq $case[0]) ('Expected Unresolved for '+$case[2]+' but got '+$r.Basis+' '+$r.Resolved)
    }
    $r=& $module $resolve $reloaded '%TEMP%\x' 'S-1-5-18'
    Check ($r.Basis -ceq 'Machine' -and $r.Resolved -ceq 'C:\Windows\TEMP\x') 'SYSTEM-level TEMP should resolve from the machine layer.'
    $r=& $module $resolve $reloaded 'D:\data\x' $null
    Check ($r.Basis -ceq 'Literal' -and $r.Resolved -ceq 'D:\data\x' -and @($r.Variables).Count -eq 0) 'Literal absolute path.'
    $r=& $module $resolve $reloaded '\\srv\share\x' $null
    Check ($r.Basis -ceq 'Literal') 'Literal UNC path.'

    # Old inventories have no context: every variable or relative path is Unresolved, never a local expansion.
    foreach($legacy in @($null,([pscustomobject]@{}))){
        foreach($raw in @('%WSM_N9C_APP%\x','%SystemDrive%\x','%USERPROFILE%\x','%windir%\x','rel\x')){
            $r=& $module $resolve $legacy $raw $svcSid
            Check ($r.Basis -ceq 'Unresolved' -and $null -eq $r.Resolved) ('Legacy inventory without context must be Unresolved for '+$raw)
        }
    }
    $legacyInventory=& $module { New-WsmInventory ([pscustomobject]@{HostId='11111111-2222-3333-4444-555555555555';Fingerprint=('a'*64);Name='old';OS='fixture';Version='1'}) 1 @() }
    Check ($null -eq (& $module { param($i) Get-WsmInventorySourceResolutionContext $i } $legacyInventory)) 'Old inventory must report no context.'

    # Manager restart / another machine: a fresh process with different variables gives identical answers.
    $paths=@(@('%WSM_N9C_APP%\data\a.exe',''),@('%SystemDrive%\inetpub',''),@('%USERPROFILE%\docs',$svcSid),@('%APPDATA%\v',$svcSid),@('%LOCALAPPDATA%\v',$svcSid),@('%CUSTOM%\x',''),@('rel\x',''),@('C:\a\..\b',''),@('%USERPROFILE%\x',$noProfileSid),@('D:\lit',''))
    $inProc=@(foreach($p in $paths){$sid=$p[1];if(-not $sid){$sid=$null};& $module $resolve $reloaded $p[0] $sid}) | ConvertTo-Json -Depth 6 -Compress
    $ctxFile=Join-Path $work 'ctx.json';[IO.File]::WriteAllText($ctxFile,$json)
    $childFile=Join-Path $work 'child.ps1'
    [IO.File]::WriteAllText($childFile,@'
param($Manifest,$ContextFile,$PathsFile)
$ErrorActionPreference='Stop'
$m=Import-Module $Manifest -Force -PassThru -DisableNameChecking 3>$null
$ctx=[IO.File]::ReadAllText($ContextFile)|ConvertFrom-Json
$paths=[IO.File]::ReadAllText($PathsFile)|ConvertFrom-Json
$out=@(foreach($p in @($paths)){$sid=[string]$p.Sid;if(-not $sid){$sid=$null};& $m {param($c,$raw,$s) Resolve-WsmSourcePath $raw $c $s} $ctx ([string]$p.Raw) $sid})
[Console]::Out.Write(($out|ConvertTo-Json -Depth 6 -Compress))
'@)
    $pathsFile=Join-Path $work 'paths.json';[IO.File]::WriteAllText($pathsFile,(@(foreach($p in $paths){[pscustomobject]@{Raw=$p[0];Sid=$p[1]}})|ConvertTo-Json -Compress))
    foreach($variant in @(@{Name='Target-like';Env=@{WSM_N9C_APP='T:\TargetOnly';USERPROFILE='T:\Users\target';SystemDrive='T:';APPDATA='T:\a';LOCALAPPDATA='T:\l'}},@{Name='Restarted Manager';Env=@{WSM_N9C_APP='Z:\Other';USERPROFILE='Z:\Users\other';SystemDrive='Z:';APPDATA='Z:\a';LOCALAPPDATA='Z:\l'}})){
        foreach($k in $variant.Env.Keys){[Environment]::SetEnvironmentVariable($k,$variant.Env[$k],'Process')}
        $childOut=(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $childFile -Manifest $manifest -ContextFile $ctxFile -PathsFile $pathsFile) -join ''
        Check ($LASTEXITCODE -eq 0) ('Child process failed for '+$variant.Name)
        Check ($childOut -ceq $inProc) ($variant.Name+' process resolved differently from the in-process result.')
    }

    # Five call sites. 1a/1b: software consumer references (scheduled task Command, IIS physicalPath).
    $catalogRun={
        param($file,$inventory)
        . $file
        function Get-WsmSoftwareCaptureIdentity {[pscustomobject]@{Fingerprint=('a'*64);IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function Get-WsmSoftwareNativeSnapshots { param([int]$MaxRegistryEntries) @() }
        function Get-WsmSoftwareModuleSnapshot { param($MaxEntries) [pscustomobject]@{Status='Success';Rows=@();ErrorKind=$null;Count=0} }
        $script:Seen=New-Object System.Collections.Generic.List[string]
        function Get-WsmSoftwareFileMetadataSnapshot { param($Path) $script:Seen.Add([string]$Path);[pscustomobject]@{Status='Success';ErrorKind=$null;Row=[pscustomobject]@{Name='x';Version='1';Publisher='p';ProductName='x';Path=$Path;Length=1;LastWriteUtc='2026-10-23T00:00:00Z';FileKind='.exe'}} }
        function Get-WsmSoftwareAdjacentRuntimeSnapshot { param($ExecutablePath,$MaxEntries,$MaxMetadataBytes) [pscustomobject]@{Status='Success';Count=0;MetadataBytes=0;Rows=@();Gaps=@()} }
        $catalog=Get-WsmSoftwareCatalog -Source $inventory -MaxEntries 100
        Assert-WsmSoftwareCatalog $catalog -SourceInventory $inventory | Out-Null
        [pscustomobject]@{Catalog=$catalog;Seen=@($script:Seen.ToArray())}
    }
    $taskXml={param($cmd) '<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal id="A"><UserId>S-1-5-21-1-2-3-1001</UserId></Principal></Principals><Actions><Exec><Command>'+$cmd+'</Command></Exec></Actions></Task>'}
    $newInventory={
        param($context,$tasks,$sites)
        $items=New-Object System.Collections.Generic.List[object];$n=0
        foreach($cmd in $tasks){$n++;$items.Add((New-WsmItem '11111111-2222-3333-4444-555555555555' Tasks ScheduledTask ('\Job'+$n) ('\Job'+$n) @{Xml=('<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal id="A"><UserId>S-1-5-21-1-2-3-1001</UserId></Principal></Principals><Actions><Exec><Command>'+$cmd+'</Command></Exec></Actions></Task>')}))}
        foreach($site in $sites){$n++;$items.Add((New-WsmItem '11111111-2222-3333-4444-555555555555' Web IISSite ('Site'+$n) ('Site'+$n) @{Xml=('<site name="S"><application path="/"><virtualDirectory path="/" physicalPath="'+$site+'"/></application></site>')}))}
        $inv=New-WsmInventory ([pscustomobject]@{HostId='11111111-2222-3333-4444-555555555555';Fingerprint=('a'*64);Name='11111111-2222-3333-4444-555555555555';OS='fixture';Version='1'}) 1 $items.ToArray()
        if($null -ne $context){$inv | Add-Member NoteProperty SourceResolutionContext $context -Force}
        $inv
    }
    $inv=& $module $newInventory $reloaded @('%USERPROFILE%\bin\tool.exe','%CUSTOM_VAR%\tool.exe','D:\lit\tool.exe') @('%WSM_N9C_APP%\site','%OTHER_VAR%\site')
    $run=& $module $catalogRun $sourceFile $inv
    Check ($run.Seen -contains 'C:\Users\svcuser\bin\tool.exe') 'SoftwareInventory task Command did not resolve through the Source context (ProfileDerived).'
    Check ($run.Seen -contains ($appRoot+'\site')) 'SoftwareInventory IIS physicalPath did not resolve through the Source context (Manager variable leaked).'
    Check ($run.Seen -contains 'D:\lit\tool.exe') 'Literal consumer path lost.'
    Check (-not ($run.Seen | Where-Object {$_ -like 'M:*' -or $_ -like '*CUSTOM_VAR*' -or $_ -like '*OTHER_VAR*'})) 'Unresolved consumer path was looked up on the reviewing host.'
    $unresolvedCoverage=@($run.Catalog.Coverage | Where-Object {$_.Probe -ceq 'ConsumerPathResolution' -and $_.ErrorKind -ceq 'SourcePathUnresolved'})
    Check ($unresolvedCoverage.Count -eq 2 -and @($unresolvedCoverage | Where-Object Status -NE 'Partial').Count -eq 0) 'Unresolved consumer paths must be reported as unknown, not skipped silently.'
    $oldInv=& $module $newInventory $null @('%USERPROFILE%\bin\tool.exe','D:\lit\tool.exe') @('%WSM_N9C_APP%\site')
    $oldRun=& $module $catalogRun $sourceFile $oldInv
    Check ($oldRun.Seen.Count -eq 1 -and $oldRun.Seen[0] -ceq 'D:\lit\tool.exe') 'Legacy inventory fell back to local expansion for consumer paths.'
    Check (@($oldRun.Catalog.Coverage | Where-Object {$_.Probe -ceq 'ConsumerPathResolution'}).Count -eq 2) 'Legacy inventory unresolved consumers were not reported.'
    # The context is part of the inventory projection hash that binds the catalog.
    $hashWith=& $module {param($i) Get-WsmSoftwareInventoryProjectionHash $i} $inv
    $tampered=$inv | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    ($tampered.SourceResolutionContext.MachineEnvironment | Where-Object Name -EQ 'WSM_N9C_APP').Value='X:\Tampered'
    $hashTampered=& $module {param($i) Get-WsmSoftwareInventoryProjectionHash $i} $tampered
    $hashRoundTrip=& $module {param($i) Get-WsmSoftwareInventoryProjectionHash $i} ($inv | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    Check ($hashWith -ceq $hashRoundTrip -and $hashWith -cne $hashTampered) 'Source context is not bound into the inventory projection hash.'
    $rejected=$false;try{& $module {param($file,$c,$i) . $file;Assert-WsmSoftwareCatalog $c -SourceInventory $i | Out-Null} $sourceFile $run.Catalog $tampered}catch{$rejected=$true}
    Check $rejected 'Catalog stayed bound to an inventory whose context was altered.'

    # 2. Discovery path candidates (IIS virtualDirectory / configSource / Share).
    $discoveryRun={
        param($context)
        $items=@(
            (New-WsmItem '11111111-2222-3333-4444-555555555555' Web IISSite 'S1' 'S1' @{Xml='<site name="S1"><application path="/"><virtualDirectory path="/" physicalPath="%WSM_N9C_APP%\web"/><virtualDirectory path="/c" physicalPath="%CUSTOM%\c"/></application><section configSource="rel.config" /></site>'}),
            (New-WsmItem '11111111-2222-3333-4444-555555555555' Storage Share 'Data' 'Data' @{Definition=[pscustomobject]@{Path='%SystemDrive%\Shares\Data'}})
        )
        @(Get-WsmPathCandidates '11111111-2222-3333-4444-555555555555' $items $context)
    }
    $cand=& $module $discoveryRun $reloaded
    $web=@($cand | Where-Object {$_.Settings.OriginalPath -ceq '%WSM_N9C_APP%\web'})[0]
    $share=@($cand | Where-Object {$_.Settings.OriginalPath -ceq '%SystemDrive%\Shares\Data'})[0]
    $custom=@($cand | Where-Object {$_.Settings.OriginalPath -ceq '%CUSTOM%\c'})[0]
    $rel=@($cand | Where-Object {$_.Settings.OriginalPath -ceq 'rel.config'})[0]
    Check ($web.Settings.ResolvedCandidate -ceq ($appRoot+'\web') -and $web.Settings.ResolutionBasis -ceq 'Machine') 'Discovery IIS virtualDirectory candidate did not use the Source context.'
    Check ($share.Settings.ResolvedCandidate -ceq 'C:\Shares\Data' -and $share.Settings.ResolutionBasis -ceq 'Machine') 'Discovery Share candidate did not use the Source context (reviewer SystemDrive is M:).'
    Check (-not $custom.Settings.ResolvedCandidate -and $custom.Settings.ResolutionBasis -ceq 'Unresolved' -and -not $rel.Settings.ResolvedCandidate -and $rel.Settings.ResolutionBasis -ceq 'Unresolved') 'Discovery unresolved variable/relative configSource must stay unresolved.'
    $candOld=& $module $discoveryRun $null
    Check (@($candOld | Where-Object {$_.Settings.ResolvedCandidate}).Count -eq 0 -and @($candOld | Where-Object {$_.Settings.ResolutionBasis -cne 'Unresolved'}).Count -eq 0) 'Discovery without context must not resolve through the local environment.'

    # 4. WorkloadDiscovery web.config roots.
    $webRun={
        param($context)
        $site=New-WsmItem '11111111-2222-3333-4444-555555555555' Web IISSite 'WebSite' 'WebSite' @{Xml='<site name="WebSite"><application path="/"><virtualDirectory path="/" physicalPath="%WSM_N9C_APP%\site"/></application></site>'}
        @(Get-WsmIisWebConfigInventoryItems '11111111-2222-3333-4444-555555555555' @($site) -Context $context)
    }
    $webItems=& $module $webRun $reloaded
    Check (@($webItems | Where-Object {$_.Settings.PSObject.Properties['Path'] -and $_.Settings.Path -like ($appRoot+'\site\web.config')}).Count -eq 1) 'web.config root was not enumerated from the Source-context root.'
    $webOld=& $module $webRun $null
    Check (@($webOld | Where-Object {$_.Settings.Status -ceq 'UnresolvedPhysicalRoot' -and $_.Settings.ResolutionBasis -ceq 'Unresolved'}).Count -eq 1 -and @($webOld | Where-Object {$_.Settings.PSObject.Properties['Path']}).Count -eq 0) 'web.config root without context must be Unresolved and not enumerated.'

    # 3. DeveloperProbe override, exercised against the real module in a clean process.
    $probeScript=Join-Path $work 'probe.ps1'
    [IO.File]::WriteAllText($probeScript,@'
param($Manifest,$ContextFile,$AppRoot,$Helper)
$ErrorActionPreference='Stop'
$m=Import-Module $Manifest -Force -PassThru -DisableNameChecking 3>$null
$ctx=[IO.File]::ReadAllText($ContextFile)|ConvertFrom-Json
& $m { param($h) . $h } $Helper
& $m { param($mm) Install-WsmDeveloperProbeInventoryGuards -Module $mm -Salt 'n9c' } $m
$result=& $m {
    param($c,$root)
    $site=New-WsmItem '11111111-2222-3333-4444-555555555555' Web IISSite 'WebSite' 'WebSite' @{Xml='<site name="WebSite"><application path="/"><virtualDirectory path="/" physicalPath="%WSM_N9C_APP%\site"/><virtualDirectory path="/x" physicalPath="%NOT_IN_CONTEXT%\x"/><virtualDirectory path="/u" physicalPath="\\srv\share\x"/></application></site>'}
    $items=@(Get-WsmIisWebConfigInventoryItems '11111111-2222-3333-4444-555555555555' @($site) -Context $c)
    [pscustomobject]@{Roots=@($items|Where-Object {$_.Settings.PSObject.Properties['Path']}|ForEach-Object {$_.Settings.Path});Unresolved=@($items|Where-Object {$_.Settings.PSObject.Properties['Status'] -and $_.Settings.Status -ceq 'UnresolvedPhysicalRoot'}).Count;Gaps=@($script:WsmDeveloperProbeScopeGaps|ForEach-Object {$_.ReasonCode})}
} $ctx $AppRoot
[Console]::Out.Write(($result|ConvertTo-Json -Depth 5 -Compress))
'@)
    [Environment]::SetEnvironmentVariable('WSM_N9C_APP','Q:\NotTheSource','Process')
    $probeErr=Join-Path $work 'probe.err'
    $probeOut=(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probeScript -Manifest $manifest -ContextFile $ctxFile -AppRoot $appRoot -Helper (Join-Path $repo 'src\DeveloperProbe.ps1') 2>$probeErr) -join ' '
    Check ($LASTEXITCODE -eq 0) ('Developer probe child failed: '+$probeOut+' '+[IO.File]::ReadAllText($probeErr))
    $probe=$probeOut|ConvertFrom-Json
    Check (@($probe.Roots) -contains ($appRoot+'\site\web.config') -and $probe.Unresolved -ge 1 -and @($probe.Gaps) -contains 'RemoteOrDevicePathBlocked') 'DeveloperProbe override did not resolve through the Source context while keeping its safety gaps.'
    $devText=[IO.File]::ReadAllText((Join-Path $repo 'src\DeveloperProbe.ps1'))
    Check ($devText -match 'Resolve-WsmSourcePath \$raw \$Context') 'DeveloperProbe physicalPath safety check does not call the shared resolver.'

    # 5. Export-WsmInventory wiring (a real Export needs a Server): static check of the data flow.
    $invText=[IO.File]::ReadAllText((Join-Path $repo 'src\Inventory.ps1'))
    Check ($invText -match 'Get-WsmSourceResolutionContext \$hostId \$items\.ToArray\(\)' -and $invText -match 'Get-WsmIisWebConfigInventoryItems \$hostId \$siteRows -Context \$sourceResolutionContext' -and $invText -match 'Get-WsmPathCandidates \$hostId \$items\.ToArray\(\) \$sourceResolutionContext' -and $invText -match 'Add-Member NoteProperty SourceResolutionContext \$sourceResolutionContext') 'Export-WsmInventory does not capture and pass the Source context.'
    $firstWebConsumer=$invText.IndexOf('Add-Probe Web');$contextBuilt=$invText.IndexOf('Get-WsmSourceResolutionContext $hostId')
    Check ($contextBuilt -gt 0 -and $contextBuilt -lt $firstWebConsumer) 'Source context must be captured before the Web probe consumes it.'

    # Read-only capture: no registry writes or user-hive access in any context/resolver code.
    $tokens=$null;$errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'src\EnterpriseDiscovery.ps1'),[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) 'EnterpriseDiscovery does not parse.'
    $names=@('Get-WsmResolutionSystemEnvironment','Get-WsmResolutionProfileList','Get-WsmSourceResolutionContext','Get-WsmSourceResolutionContextHash','Resolve-WsmSourcePath','Get-WsmSourceAccountSid','Get-WsmInventorySourceResolutionContext','Resolve-WsmAccountToSid','Get-WsmTaskPrincipalAccount','Get-WsmWellKnownAccountSid','New-WsmSourcePathResolution')
    $funcs=@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $names -contains $n.Name},$true))
    Check ($funcs.Count -eq $names.Count) 'Not all N9c functions were found for the read-only scan.'
    $forbidden='SetValue|CreateSubKey|DeleteValue|DeleteSubKey|LoadKey|Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|Set-Item\b|New-Item\b|HKEY_USERS|HKU:|HKCU:|RegistryHive\]::(Users|CurrentUser)|NTUSER|reg(\.exe)?\s+(load|unload|add|delete)|OpenSubKey\([^)]*\$true'
    foreach($f in $funcs){Check ($f.Extent.Text -notmatch $forbidden) ('Registry write or user-hive access found in '+$f.Name)}
    # And at run time: resolving must not touch the registry at all.
    $touch={
        param($c)
        function Get-ItemProperty { throw 'registry read during resolution' }
        function Get-Item { throw 'registry read during resolution' }
        function Get-WsmResolutionProfileList { throw 'ProfileList read during resolution' }
        function Get-WsmResolutionSystemEnvironment { throw 'registry read during resolution' }
        Resolve-WsmSourcePath '%LOCALAPPDATA%\x' $c 'S-1-5-21-1-2-3-1001'
    }
    Check ((& $module $touch $reloaded).Resolved -ceq 'C:\Users\svcuser\AppData\Local\x') 'Resolution must be a pure function of the stored context.'

    # Real, read-only capture on this machine (HKLM only).
    $real=& $module { Get-WsmSourceResolutionContext '11111111-2222-3333-4444-555555555555' @((New-WsmItem '11111111-2222-3333-4444-555555555555' Services Service 'sys' 'sys' @{StartName='LocalSystem'})) }
    Check (@($real.MachineEnvironment | Where-Object Name -EQ 'SystemRoot').Count -eq 1 -and $real.ProfileListStatus -in @('Success','NotInstalled') -and @($real.Accounts)[0].Sid -ceq 'S-1-5-18') 'Real read-only capture failed.'

    # Guard: no source file may expand environment variables from the running process.
    $allowed=@()   # No location is allowed: every expansion goes through Resolve-WsmSourcePath.
    $hits=@(Get-ChildItem -LiteralPath (Join-Path $repo 'src') -Recurse -File -Include *.ps1,*.psm1 | ForEach-Object {
        $text=[IO.File]::ReadAllText($_.FullName);$lineNo=0
        foreach($line in ($text -split "`n")){$lineNo++;if($line -match 'ExpandEnvironmentVariables'){ '{0}:{1}' -f $_.Name,$lineNo }}
    } | Where-Object {$allowed -notcontains $_})
    Check ($hits.Count -eq 0) ('ExpandEnvironmentVariables is used outside the allowed list: '+($hits -join ', '))
    Write-Host ('PASS: {0} source-context resolution checks (machine layer, ProfileList derivation, Unresolved cases, three-end invariance, five call sites, legacy inventory, read-only capture, static guard).' -f $script:Checks)
} finally {
    foreach($n in $envNames){[Environment]::SetEnvironmentVariable($n,$savedEnv[$n],'Process')}
    try{Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}catch{}
}
