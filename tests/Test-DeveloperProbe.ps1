#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$helper=Join-Path $PSScriptRoot '..\src\DeveloperProbe.ps1'
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-developer-probe-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try{
    & $module {
        param($Root,$Helper)
        . $Helper
        function Assert-DeveloperProbe([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
        $worker=New-WsmDeveloperProbeWorker -ModulePath (Join-Path (Split-Path $Helper -Parent) 'WindowsServerMigration.psd1') -CollectorId CommandsModules -Role Manager -Origin '' -RawRoot $Root -Salt 'native-worker-test' -Adapter $null
        try{
            $deadline=[Diagnostics.Stopwatch]::StartNew();while(-not $worker.Async.IsCompleted -and $deadline.Elapsed.TotalSeconds -lt 30){Start-Sleep -Milliseconds 50}
            if(-not $worker.Async.IsCompleted){$worker.PowerShell.Stop();throw 'Native CommandsModules worker did not finish within its bounded test window.'}
            $nativeOutput=@(Receive-WsmDeveloperProbeWorkerOutput $worker);$nativeErrors=@(if($worker.PowerShell){$worker.PowerShell.Streams.Error})
            Assert-DeveloperProbe ($nativeErrors.Count -eq 0) ('Native CommandsModules worker reported errors: '+($nativeErrors|ForEach-Object Exception|ForEach-Object Message -join '; '))
            Assert-DeveloperProbe ($nativeOutput.Count -gt 0 -and @($nativeOutput[-1].Commands).Count -eq 16 -and $null -ne $nativeOutput[-1].Modules) 'Native CommandsModules did not return all 16 command rows and structured module capability data.'
            $taskModule=Get-Module -ListAvailable -Name ScheduledTasks|Sort-Object Version -Descending|Select-Object -First 1;$taskCommand=@($nativeOutput[-1].Commands|Where-Object Name -CEQ 'Get-ScheduledTask')[0];$taskDiscoverable=[bool]($taskModule -and $taskModule.ExportedCommands.ContainsKey('Get-ScheduledTask'))
            Assert-DeveloperProbe ($taskCommand.Available -eq ($taskCommand.Loaded -or $taskDiscoverable) -and $taskCommand.DiscoverableInstalled -eq $taskDiscoverable -and $taskCommand.CapabilityStatus -in @('Loaded','AvailableInInstalledModule','Unavailable')) ('A discoverable installed command was incorrectly reported as unavailable. Row='+($taskCommand|ConvertTo-Json -Compress)+'; modules='+(@($nativeOutput[-1].Modules|ConvertTo-Json -Compress)))
            Write-Host ('PASS: native CommandsModules worker counts: commands={0}; modules={1}.' -f @($nativeOutput[-1].Commands).Count,@($nativeOutput[-1].Modules).Count)
        }finally{Dispose-WsmDeveloperProbeWorker $worker}
        $actualRaw=Join-Path $Root 'native-actual-raw';[void][IO.Directory]::CreateDirectory($actualRaw)
        $actualModulePath=Join-Path (Split-Path $Helper -Parent) 'WindowsServerMigration.psd1';$originalModulePath=$env:PSModulePath
        try{
            $env:PSModulePath='\\DEVPROBE_UNC_SENTINEL\module-root'+[IO.Path]::PathSeparator+$originalModulePath
            $sentinelModulePath=$env:PSModulePath;$actualWorker=New-WsmDeveloperProbeWorker -ModulePath $actualModulePath -CollectorId NativeInventory -Role Manager -Origin '' -RawRoot $actualRaw -Salt 'actual-native-autoload' -Adapter $null
            Assert-DeveloperProbe ($actualWorker.ChildModulePath -notmatch 'DEVPROBE_UNC_SENTINEL' -and $actualWorker.ChildModulePath -notmatch '^\\\\') 'The isolated native child inherited a UNC PSModulePath sentinel.'
            foreach($childRoot in @($actualWorker.ChildModulePath -split [regex]::Escape([IO.Path]::PathSeparator))){$childRootCheck=Test-WsmDeveloperProbeSafeProcessModuleRoot $childRoot;Assert-DeveloperProbe ($childRootCheck.Allowed) ('The native child PSModulePath contains an unvalidated module root: '+$childRootCheck.ReasonCode)}
            try{$actualDeadline=[Diagnostics.Stopwatch]::StartNew();while(-not $actualWorker.Async.IsCompleted -and $actualDeadline.Elapsed.TotalSeconds -lt 90){Assert-DeveloperProbe ($env:PSModulePath -ceq $sentinelModulePath) 'The actual native worker modified process PSModulePath while running.';Start-Sleep -Milliseconds 50};if(-not $actualWorker.Async.IsCompleted){Stop-WsmDeveloperProbeWorker $actualWorker;throw 'The actual native inventory preflight exceeded 90 seconds.'};try{$actualOutput=@(Receive-WsmDeveloperProbeWorkerOutput $actualWorker)}catch{throw ('Actual native worker failed: '+$_.Exception.Message)};$actualErrors=@(if($actualWorker.PowerShell){$actualWorker.PowerShell.Streams.Error});Assert-DeveloperProbe ($actualErrors.Count -eq 0 -and $actualOutput.Count -gt 0 -and $actualOutput[-1].Status -in @('Captured','NotApplicable','PermissionDenied')) ('Actual native CIM preflight/collector failed with PSModulePath containing a UNC sentinel: '+($actualErrors|ForEach-Object Exception|ForEach-Object Message -join '; '));Assert-DeveloperProbe ($env:PSModulePath -ceq $sentinelModulePath) 'The native child process changed parent PSModulePath.';if($actualOutput[-1].Status -eq 'Captured'){Assert-DeveloperProbe (@($actualOutput[-1].ScopeGaps|Where-Object {$_.Path -like '*DEVPROBE_UNC_SENTINEL*' -and $_.ReasonCode -eq 'RemoteOrDevicePathBlocked'}).Count -gt 0) 'The native collector did not report its rejected UNC module discovery root.'}}finally{Dispose-WsmDeveloperProbeWorker $actualWorker}
            Write-Host ('PASS: actual NativeInventory with UNC PSModulePath sentinel; outcome={0}.' -f $actualOutput[-1].Status)
        }finally{$env:PSModulePath=$originalModulePath}
        $completedProcess=[pscustomobject]@{HasExited=$true;ExitCode=0}
        $escapedEnvelope=[pscustomobject]@{Process=$completedProcess;ResultPath=(Join-Path $Root 'outside-worker-envelope.json');RawRoot=$actualRaw}
        $escapedRejected=$false;try{$null=Receive-WsmDeveloperProbeWorkerOutput $escapedEnvelope}catch{$escapedRejected=$_.Exception.Message -like '*escaped its protected raw root*'}
        Assert-DeveloperProbe $escapedRejected 'The native child result reader accepted an envelope outside its protected raw root.'
        $oversizedEnvelopePath=Join-Path $actualRaw 'oversized-worker-envelope.json';$oversizedStream=[IO.File]::Open($oversizedEnvelopePath,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$oversizedStream.SetLength(16777217)}finally{$oversizedStream.Dispose()}
        $oversizedEnvelope=[pscustomobject]@{Process=$completedProcess;ResultPath=$oversizedEnvelopePath;RawRoot=$actualRaw}
        $oversizedRejected=$false;try{$null=Receive-WsmDeveloperProbeWorkerOutput $oversizedEnvelope}catch{$oversizedRejected=$_.Exception.Message -like '*bounded read size*'}
        Assert-DeveloperProbe $oversizedRejected 'The native child result reader accepted an over-budget envelope.'
        Remove-Item -LiteralPath $oversizedEnvelopePath -Force
        $budgetModuleRoot=Join-Path $Root 'module-entry-budget';[void][IO.Directory]::CreateDirectory($budgetModuleRoot);$manifestText="@{ ModuleVersion='1.0'; FunctionsToExport='*' }"
        for($moduleIndex=0;$moduleIndex -lt 2001;$moduleIndex++){[IO.File]::WriteAllText((Join-Path $budgetModuleRoot ('module-'+$moduleIndex.ToString('D4')+'.psd1')),$manifestText,(New-Object Text.UTF8Encoding($true)))}
        $previousModulePath=$env:PSModulePath;$budgetOutput=@();$budgetErrors=@()
        try{$env:PSModulePath=$budgetModuleRoot;$budgetWorker=New-WsmDeveloperProbeWorker -ModulePath (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -CollectorId CommandsModules -Role Manager -Origin '' -RawRoot $Root -Salt 'module-entry-budget' -Adapter $null
            try{$budgetDeadline=[Diagnostics.Stopwatch]::StartNew();while(-not $budgetWorker.Async.IsCompleted -and $budgetDeadline.Elapsed.TotalSeconds -lt 90){Start-Sleep -Milliseconds 50};if(-not $budgetWorker.Async.IsCompleted){Stop-WsmDeveloperProbeWorker $budgetWorker;throw 'Bounded module discovery exceeded its 90-second fixture window.'};$budgetOutput=@(Receive-WsmDeveloperProbeWorkerOutput $budgetWorker);$budgetErrors=@(if($budgetWorker.PowerShell){$budgetWorker.PowerShell.Streams.Error})}finally{Dispose-WsmDeveloperProbeWorker $budgetWorker}
        }finally{$env:PSModulePath=$previousModulePath}
        Assert-DeveloperProbe ($budgetErrors.Count -eq 0 -and $budgetOutput.Count -gt 0) ('Bounded module discovery worker failed: '+($budgetErrors|ForEach-Object Exception|ForEach-Object Message -join '; '))
        Assert-DeveloperProbe ($budgetOutput[-1].Status -eq 'Partial' -and @($budgetOutput[-1].ScopeGaps|Where-Object ReasonCode -eq 'ModuleEntryCountBudgetExceeded').Count -eq 1) 'A capped module list dropped entries while still reporting complete discovery.'
        Assert-DeveloperProbe (@($budgetOutput[-1].Modules).Count -eq 5) 'The module discovery entry cap corrupted command capability output.'
        $unmockedWorkspace=Join-Path $Root 'unmocked-export';[void][IO.Directory]::CreateDirectory($unmockedWorkspace)
        $expectedOs=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $expectedFixedVolumes=@(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop|ForEach-Object {[string]$_.DeviceID}|Sort-Object -Unique)
        $unmockedResult=Export-WsmDeveloperProbe -Workspace $unmockedWorkspace -Role Manager
        $platformRow=@($unmockedResult.CollectorResults|Where-Object Id -eq PlatformIdentity)[0];$volumeRow=@($unmockedResult.CollectorResults|Where-Object Id -eq LocalVolumes)[0];$nativeRow=@($unmockedResult.CollectorResults|Where-Object Id -eq NativeInventory)[0]
        Assert-DeveloperProbe ($platformRow.Status -eq 'Completed' -and $volumeRow.Status -eq 'Completed') ('Unmocked basic collectors did not complete after explicit trusted CIM import: '+(@($platformRow,$volumeRow)|ConvertTo-Json -Depth 8 -Compress))
        Assert-DeveloperProbe ($platformRow.Data.OS -ceq [string]$expectedOs.Caption -and $platformRow.Data.Version -ceq [string]$expectedOs.Version -and $platformRow.Data.Build -ceq [string]$expectedOs.BuildNumber) 'Unmocked platform identity differs from local native CIM OS/build data.'
        $observedFixedVolumes=@($volumeRow.Data.Volumes|ForEach-Object {([string]$_.DriveAlias -replace '^volume-','').ToUpperInvariant()+':'}|Sort-Object -Unique)
        Assert-DeveloperProbe ((@($expectedFixedVolumes|Sort-Object) -join '|') -ceq ($observedFixedVolumes -join '|')) ('Unmocked fixed-volume set differs from local native CIM. expected='+($expectedFixedVolumes -join ',')+' observed='+($observedFixedVolumes -join ','))
        Assert-DeveloperProbe ($nativeRow.Status -in @('Completed','Partial','NotApplicable','PermissionDenied')) ('Native inventory did not report an applicable platform/permission outcome truthfully: '+$nativeRow.Status)
        Write-Host ('PASS: unmocked developer probe OS/build and fixed volumes match native CIM; NativeInventory={0}.' -f $nativeRow.Status)
        $guardRoot=Join-Path $Root 'native-scope-guard';[void][IO.Directory]::CreateDirectory($guardRoot)
        $guardLocal=Join-Path $guardRoot 'local';[void][IO.Directory]::CreateDirectory($guardLocal)
        $guardTarget=Join-Path $guardRoot 'target';[void][IO.Directory]::CreateDirectory($guardTarget)
        $guardLink=Join-Path $guardRoot 'reparse-link';$guardLinkCreated=$false
        try{New-Item -ItemType Junction -Path $guardLink -Target $guardTarget -ErrorAction Stop|Out-Null;$guardLinkCreated=$true}catch{}
        if(-not $guardLinkCreated){throw 'The developer probe safety fixture requires a local temporary junction to verify reparse-ancestor rejection.'}
        $fixtureModuleRoot=Join-Path $guardRoot 'fixture-module';[void][IO.Directory]::CreateDirectory($fixtureModuleRoot)
        Copy-Item -LiteralPath $Helper -Destination (Join-Path $fixtureModuleRoot 'DeveloperProbe.ps1')
        $fixtureManifest=Join-Path $fixtureModuleRoot 'WindowsServerMigration.psd1'
        [IO.File]::WriteAllText($fixtureManifest,"@{ RootModule='WindowsServerMigration.psm1'; ModuleVersion='0.0.1'; GUID='c54ed8aa-4fa4-49b3-a93a-7fb0fdfad213'; PowerShellVersion='5.1'; FunctionsToExport='*' }",(New-Object Text.UTF8Encoding($true)))
        $fixtureModule=@'
$script:Calls=[ordered]@{FileMetadata=@();Adjacent=@();Resolve=@();IisRoots=@();Dfs=0;ConfigSource=0;Hosts=0;Redirection=0}
function Get-WsmPreflight { [pscustomobject]@{IsServer=$true;Administrator=$true;Is64Bit=$true;OS='Fixture';Version='1';Build='1'} }
function New-WsmItem { param($HostId,$Category,$Kind,$Name,$NaturalKey,$Settings,$Dependencies,$Status) [pscustomobject]@{HostId=$HostId;ItemId=([guid]::NewGuid().ToString());Category=$Category;Kind=$Kind;Name=$Name;NaturalKey=$NaturalKey;Settings=$Settings;Dependencies=@($Dependencies);Status=$Status} }
function Read-WsmXml([string]$Text) { $xml=New-Object Xml.XmlDocument;$xml.PreserveWhitespace=$true;$xml.LoadXml($Text);$xml }
function Resolve-WsmSourcePath { param([string]$Raw,$Context,[string]$AccountSid) $script:Calls.Resolve+=@($Raw);if($Raw -match '%'){[pscustomobject]@{Raw=$Raw;Resolved=$null;Basis='Unresolved';Variables=@();Reason='FixtureNoContext'}}else{[pscustomobject]@{Raw=$Raw;Resolved=$Raw;Basis='Literal';Variables=@();Reason=''}} }
function Get-WsmSoftwareModuleSnapshot { param([int]$MaxEntries=2000) [pscustomobject]@{Status='Success';Rows=@([pscustomobject]@{Name='LocalFixtureModule';Version='1.0';Path=$env:WSM_GUARD_LOCAL;ModuleBase=$env:WSM_GUARD_LOCAL});ErrorKind=$null;Count=1;Budget=@{MaxEntries=$MaxEntries}} }
function Get-WsmSoftwareFileMetadataSnapshot { param([string]$Path) $script:Calls.FileMetadata+=@($Path);[pscustomobject]@{Status='Success';ErrorKind=$null;Row=[pscustomobject]@{Name='fixture';Version='1';Path=$Path}} }
function Get-WsmSoftwareAdjacentRuntimeSnapshot { param([string]$ExecutablePath,[int]$MaxEntries=200,[long]$MaxMetadataBytes=1048576) $script:Calls.Adjacent+=@($ExecutablePath);[pscustomobject]@{Status='Success';Rows=@();Gaps=@();Count=0;MetadataBytes=0} }
function Get-WsmIisWebConfigInventoryItems { param([string]$HostId,[object[]]$SiteItems,[int]$MaxDirectories=4096,[int]$MaxFiles=8192,[long]$MaxBytes=67108864,[int]$MaxFileBytes=4194304) foreach($site in $SiteItems){$xml=Read-WsmXml $site.Settings.Xml;foreach($node in @($xml.SelectNodes("//*[local-name()='virtualDirectory'][@physicalPath]"))){$script:Calls.IisRoots+=@([string]$node.GetAttribute('physicalPath'));[pscustomobject]@{Kind='IISWebConfig';Status='Success';Path=[string]$node.GetAttribute('physicalPath')}}} }
function Get-WsmIisConfigSourceEvidence { param($Node,[string]$ConfigurationPath) $script:Calls.ConfigSource++;[pscustomobject]@{Status='Captured';RelativePath=[string]$Node.GetAttribute('configSource');ResolvedPath=$ConfigurationPath;SHA256=('a'*64);ProtectedXml='<safe />';Reason=''} }
function Get-WsmHostsText { $script:Calls.Hosts++;[IO.File]::ReadAllText((Join-Path $env:windir 'System32\drivers\etc\hosts')) }
function Get-WsmIisRedirectionText { $script:Calls.Redirection++;$path=Join-Path $env:windir 'System32\inetsrv\config\redirection.config';if([IO.File]::Exists($path)){[IO.File]::ReadAllText($path)} }
function Get-WsmEnterpriseDiscovery { param([string]$HostId,[switch]$Deep) $null=Get-WsmHostsText;$null=Get-WsmIisRedirectionText;try{Get-DfsnRoot -Path '\\DEVPROBE_UNC_SENTINEL\share\*' -ErrorAction Stop}catch{New-WsmItem $HostId Storage CollectorFailure 'DFS probe blocked' 'dfs-blocked' @{ErrorType=$_.Exception.GetType().Name} @() Partial} }
function Get-DfsnRoot { param([string]$Path) $script:Calls.Dfs++;@('UNSAFE_DFS_RESULT') }
function Export-WsmInventory { param([string]$OutputDirectory,[switch]$DeepDiscovery,[switch]$IncludeSoftwareCatalog)
 $local=$env:WSM_GUARD_LOCAL;$unc='\\DEVPROBE_UNC_SENTINEL\share\service.exe';$junction=(Join-Path $env:WSM_GUARD_LINK 'service.exe')
 $fileRows=@((Get-WsmSoftwareFileMetadataSnapshot -Path (Join-Path $local 'service.exe')),(Get-WsmSoftwareFileMetadataSnapshot -Path $unc),(Get-WsmSoftwareFileMetadataSnapshot -Path $junction))
 $runtimeRows=@((Get-WsmSoftwareAdjacentRuntimeSnapshot -ExecutablePath (Join-Path $local 'service.exe')),(Get-WsmSoftwareAdjacentRuntimeSnapshot -ExecutablePath $unc),(Get-WsmSoftwareAdjacentRuntimeSnapshot -ExecutablePath $junction))
 $siteXml='<site><application><virtualDirectory path="/" physicalPath="'+$local+'"/><virtualDirectory path="/unc" physicalPath="'+$unc+'"/><virtualDirectory path="/junction" physicalPath="'+$env:WSM_GUARD_LINK+'"/></application></site>'
 $site=[pscustomobject]@{ItemId='fixture-site';NaturalKey='fixture-site';Settings=[pscustomobject]@{Xml=$siteXml}}
 $iis=@(Get-WsmIisWebConfigInventoryItems 'fixture-host' @($site))
 $sourceNode=New-Object Xml.XmlDocument;$sourceNode.LoadXml('<section configSource="child.config" />');$null=Get-WsmIisConfigSourceEvidence $sourceNode.DocumentElement (Join-Path $env:WSM_GUARD_LINK 'applicationHost.config')
 $null=Test-Path -LiteralPath $unc
 $enterprise=@(Get-WsmEnterpriseDiscovery 'fixture-host' -Deep)
 $items=@($iis)+@($enterprise)+@($fileRows|Where-Object Status -ne 'Success')+@($runtimeRows|Where-Object Status -ne 'Success')
 $inventory=[pscustomobject]@{ToolVersion='0.4.0';ToolFingerprint=('b'*64);Source=[pscustomobject]@{HostId='fixture-host';Fingerprint=('c'*64);Name='fixture-host';DiscoveryDepth='Deep'};Items=$items;Calls=$script:Calls;WorkloadDiscovery=[pscustomobject]@{Kind='WorkloadDiscovery';References=@();SharedResources=@();RuntimeObservations=@();ProducerProvenance=@();ConfigurationCoverage=@();Coverage=@();CompletenessReason='Fixture'};SoftwareCatalog=[pscustomobject]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='SoftwareCatalog';CaptureContext=@{};Entries=@();Coverage=@();PreparationRequirements=@()}}
 $path=Join-Path $OutputDirectory 'fixture-inventory.json';$json=ConvertTo-Json -InputObject $inventory -Depth 30;[IO.File]::WriteAllText($path,$json,(New-Object Text.UTF8Encoding($false)));[pscustomobject]@{Path=$path;SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
}
'@
        [IO.File]::WriteAllText((Join-Path $fixtureModuleRoot 'WindowsServerMigration.psm1'),$fixtureModule,(New-Object Text.UTF8Encoding($true)))
        $oldLocal=$env:WSM_GUARD_LOCAL;$oldLink=$env:WSM_GUARD_LINK;$oldWindowsRoot=$env:windir;$env:WSM_GUARD_LOCAL=$guardLocal;$env:WSM_GUARD_LINK=$guardLink;$env:windir=$guardLink
        $guardRaw=Join-Path $guardRoot 'raw';[void][IO.Directory]::CreateDirectory($guardRaw)
        try{
            $modulePathBefore=$env:PSModulePath;$guardWorker=New-WsmDeveloperProbeWorker -ModulePath $fixtureManifest -CollectorId NativeInventory -Role Manager -Origin '' -RawRoot $guardRaw -Salt 'scope-fixture' -Adapter $null
            try{$guardDeadline=[Diagnostics.Stopwatch]::StartNew();while(-not $guardWorker.Async.IsCompleted -and $guardDeadline.Elapsed.TotalSeconds -lt 30){Assert-DeveloperProbe ($env:PSModulePath -ceq $modulePathBefore) 'A concurrent worker changed process-wide PSModulePath while the probe was active.';Start-Sleep -Milliseconds 50};if(-not $guardWorker.Async.IsCompleted){Stop-WsmDeveloperProbeWorker $guardWorker;throw 'The isolated NativeInventory scope fixture exceeded its bounded test window.'};$guardOutput=@(Receive-WsmDeveloperProbeWorkerOutput $guardWorker);$guardErrors=@(if($guardWorker.PowerShell){$guardWorker.PowerShell.Streams.Error});Assert-DeveloperProbe ($guardErrors.Count -eq 0) ('Guarded isolated NativeInventory fixture failed: '+($guardErrors|ForEach-Object Exception|ForEach-Object Message -join '; '));Assert-DeveloperProbe ($env:PSModulePath -ceq $modulePathBefore) 'The isolated NativeInventory worker changed process-wide PSModulePath.'}finally{Dispose-WsmDeveloperProbeWorker $guardWorker}
            Assert-DeveloperProbe ($guardOutput.Count -gt 0 -and $guardOutput[-1].Status -eq 'Captured') 'Guarded isolated NativeInventory worker did not retain local fixture inventory.'
            $fixtureInventory=[IO.File]::ReadAllText([string]$guardOutput[-1].InventoryPath)|ConvertFrom-Json;$scopeGaps=@($guardOutput[-1].ScopeGaps)
            Assert-DeveloperProbe (@($fixtureInventory.Items|Where-Object {$_.PSObject.Properties['Kind'] -and $_.Kind -eq 'IISWebConfig' -and $_.Path -eq $guardLocal}).Count -eq 1 -and @($fixtureInventory.Items|Where-Object {$_.PSObject.Properties['Kind'] -and $_.Kind -eq 'IISWebConfig' -and $_.Path -like '*DEVPROBE_UNC_SENTINEL*'}).Count -eq 0) 'Mixed IIS inventory lost supported local evidence or traversed the UNC root.'
            Assert-DeveloperProbe (@($scopeGaps|Where-Object {$_.ReasonCode -eq 'RemoteOrDevicePathBlocked'}).Count -ge 2 -and @($scopeGaps|Where-Object {$_.ReasonCode -eq 'ReparseAncestorBlocked'}).Count -ge 3) ('Unsafe path omissions were not retained with structured reason codes: '+($scopeGaps|ConvertTo-Json -Depth 5 -Compress))
            Assert-DeveloperProbe ($fixtureInventory.Calls.Dfs -eq 0 -and $fixtureInventory.Calls.Hosts -eq 0 -and $fixtureInventory.Calls.Redirection -eq 0 -and @($fixtureInventory.Calls.FileMetadata|Where-Object {$_ -like '*DEVPROBE_UNC_SENTINEL*' -or $_ -like '*reparse-link*'}).Count -eq 0 -and @($fixtureInventory.Calls.FileMetadata|Where-Object {$_ -like '*service.exe'}).Count -eq 1 -and @($fixtureInventory.Calls.Adjacent|Where-Object {$_ -like '*DEVPROBE_UNC_SENTINEL*' -or $_ -like '*reparse-link*'}).Count -eq 0) 'A guarded collector called a forbidden UNC/reparse target or dropped the safe local metadata probe.'
        }finally{$env:WSM_GUARD_LOCAL=$oldLocal;$env:WSM_GUARD_LINK=$oldLink;$env:windir=$oldWindowsRoot;try{Remove-Item -LiteralPath $guardLink -Force -ErrorAction SilentlyContinue}catch{}}
        $secret='DEVPROBE_SENTINEL_7f8c'
        $rawDiagnostic='password="two words '+$secret+'" <setting token="'+$secret+'" /> Authorization: Bearer '+$secret+' at C:\Users\private user\'+$secret+'.xml'
        $safeDiagnostic=ConvertTo-WsmDeveloperProbeSafeText $rawDiagnostic 'test-run-salt'
        Assert-DeveloperProbe (-not $safeDiagnostic.Contains($secret)) 'Quoted, XML and embedded diagnostic secrets were not redacted.'
        $knownHostAlias='['+(Get-WsmDeveloperProbeSafeAlias 'node-private-identity' 'host' 'test-run-salt')+']'
        $safeHostDiagnostic=ConvertTo-WsmDeveloperProbeSafeText 'probe failed on host=node-private-identity' 'test-run-salt'
        Assert-DeveloperProbe ($safeHostDiagnostic.Contains($knownHostAlias)) 'A hostname in diagnostic text was not mapped to the stable run alias.'
        $adapter={
            param($CollectorId,$Context)
            switch($CollectorId){
                PlatformIdentity { [pscustomobject]@{OS='Windows Server Fixture';Version='10.0';Build='fixture';Administrator=$true;IsServer=$true;Is64Bit=$true;Password='DEVPROBE_SENTINEL_7f8c';Credential=[pscustomobject]@{Provider='fixture';Token='DEVPROBE_SENTINEL_7f8c';Enabled=$true;RetryCount=3};PrivateKeyMaterial=@('DEVPROBE_SENTINEL_7f8c',12,$false);HostName='node-private-identity';OtherHostName='other-private-identity'} }
                CommandsModules { [pscustomobject]@{Commands=@([pscustomobject]@{Name='Get-ScheduledTask';Available=$true});Modules=@()} }
                LocalVolumes { [pscustomobject]@{Volumes=@([pscustomobject]@{DriveAlias='volume-c';FreeBytes=1000;Path='C:\Users\private user\private.txt'},[pscustomobject]@{DriveAlias='volume-c';FreeBytes=1000;Path='C:\Users\private user\private.txt'},[pscustomobject]@{DriveAlias='volume-d';FreeBytes=900;Path='D:\private user\private.txt'})} }
                NativeInventory { [pscustomobject]@{Status='Captured';InventorySHA256=('a'*64);Inventory=[pscustomobject]@{ToolVersion='fixture-version';ToolFingerprint=@{PowerShell='5.1';HostName='node-private-identity';MachineGuid='machine-guid-private'};Source=@{Name='node-private-identity';DiscoveryDepth='Deep';Fingerprint='raw-machine-fingerprint'};Items=@([pscustomobject]@{ItemId='item-fixture-1';Category='Service';Kind='WindowsService';Name='ExampleSvc';Version='1.2';Type='Win32OwnProcess';Status='Success';Dependencies=@('Tcpip');Path='C:\Program Files\private user\service.exe';Filename='private-DEVPROBE_SENTINEL_7f8c.xml';'DEVPROBE_SENTINEL_7f8c'='private field value'});WorkloadDiscovery=@{Kind='WorkloadDiscovery';References=@([pscustomobject]@{ReferenceKind='IISBinding';ConsumerItemId='item-fixture-1';ResourceItemId='resource-1';Value='https://example.test';Path='C:\inetpub\private user\web.config'});SharedResources=@();RuntimeObservations=@();ProducerProvenance=@();ConfigurationCoverage=@();Coverage=@();Complete=$false;CompletenessReason='Needs owner review'};SoftwareCatalog=@{SchemaVersion=1;ToolVersion='fixture';Kind='SoftwareCatalog';CaptureContext=@{PowerShellVersion='5.1';AccountContext='Unknown'};Entries=@([pscustomobject]@{SoftwareId='soft-fixture-1';DisplayName='Example Runtime';Version='3.4.5';Publisher='Example';CaptureStatus='Success';ItemIds=@('item-fixture-1');Dependencies=@('runtime-a')});Coverage=@([pscustomobject]@{Probe='UninstallRegistry';Scope='Machine';Status='Success';Count=1});PreparationRequirements=@()}}} }
                HttpProbe { [pscustomobject]@{Status='Failed';Error='Authorization: Bearer DEVPROBE_SENTINEL_7f8c';Headers=@{'X-Private-Token'='DEVPROBE_SENTINEL_7f8c'};ErrorMessage='password="two words DEVPROBE_SENTINEL_7f8c" at C:\Users\private user\DEVPROBE_SENTINEL_7f8c.xml'} }
            }
        }
        $expectedToolFingerprint=Get-WsmToolFingerprint
        $syntheticStatusAdapter=[scriptblock]::Create(@'
param($CollectorId,$Context)
if($CollectorId -ne 'NativeInventory'){return [pscustomobject]@{Status='Completed';Rows=@()}}
$itemStatus=if($Context.RawRoot -like '*inventory-coverage-status*'){'Partial'}else{'Success'}
$inventory=[pscustomobject]@{ToolVersion='fixture-version';ToolFingerprint=('a'*64);Source=[pscustomobject]@{Name='fixture-host';DiscoveryDepth='Deep';Fingerprint='fixture-host-fingerprint'};Items=@([pscustomobject]@{ItemId='fixture-item';Category='Service';Kind='WindowsService';Status=$itemStatus;Settings=[pscustomobject]@{ErrorKind='FixtureCoverageGap'}});WorkloadDiscovery=[pscustomobject]@{Kind='WorkloadDiscovery';References=@();SharedResources=@();RuntimeObservations=@();ProducerProvenance=@();ConfigurationCoverage=@();Coverage=@();CompletenessReason='Fixture'};SoftwareCatalog=[pscustomobject]@{SchemaVersion=1;ToolVersion='fixture-version';Kind='SoftwareCatalog';CaptureContext=@{};Entries=@();Coverage=@();PreparationRequirements=@()}}
$scopeGaps=if($Context.RawRoot -like '*scope-status*'){@([pscustomobject]@{Collector='NativeInventory';Operation='FixtureScope';ReasonCode='RemoteOrDevicePathBlocked';Path='\\DEVPROBE_UNC_SENTINEL\share\private.txt';ItemId='fixture';Action='SkippedBeforeEnumerationOrRead'})}else{@()}
[pscustomobject]@{Status='Captured';InventorySHA256=('a'*64);Inventory=$inventory;ScopeGaps=$scopeGaps}
'@)
        $scopeWorkspace=Join-Path $Root 'scope-status';[void][IO.Directory]::CreateDirectory($scopeWorkspace)
        $scopeStatusResult=Export-WsmDeveloperProbe -Workspace $scopeWorkspace -CollectorAdapter @{PlatformIdentity=$syntheticStatusAdapter;CommandsModules=$syntheticStatusAdapter;LocalVolumes=$syntheticStatusAdapter;NativeInventory=$syntheticStatusAdapter}
        $scopeStatusRow=@($scopeStatusResult.CollectorResults|Where-Object Id -eq NativeInventory)[0]
        Assert-DeveloperProbe ($scopeStatusResult.Status -eq 'Partial' -and $scopeStatusRow.Status -eq 'Partial' -and $scopeStatusRow.ReasonCode -eq 'UnsafeScopeSkipped' -and $scopeStatusRow.Data.ScopeGaps[0].ReasonCode -eq 'RemoteOrDevicePathBlocked') ('A native inventory with explicit unsafe-scope gaps was incorrectly reported complete: '+($scopeStatusResult|ConvertTo-Json -Depth 8 -Compress))
        $incompleteWorkspace=Join-Path $Root 'inventory-coverage-status';[void][IO.Directory]::CreateDirectory($incompleteWorkspace)
        $incompleteResult=Export-WsmDeveloperProbe -Workspace $incompleteWorkspace -CollectorAdapter @{PlatformIdentity=$syntheticStatusAdapter;CommandsModules=$syntheticStatusAdapter;LocalVolumes=$syntheticStatusAdapter;NativeInventory=$syntheticStatusAdapter}
        $incompleteRow=@($incompleteResult.CollectorResults|Where-Object Id -eq NativeInventory)[0]
        Assert-DeveloperProbe ($incompleteResult.Status -eq 'Partial' -and $incompleteRow.Status -eq 'Partial' -and $incompleteRow.ReasonCode -eq 'InventoryCoverageIncomplete' -and $incompleteRow.Data.IncompleteCount -gt 0 -and @($incompleteRow.Data.CoverageGaps|Where-Object Source -eq 'InventoryItem').Count -eq 1) 'Native inventory item failures without probe-scope gaps were incorrectly reported complete.'
        $workspace=Join-Path $Root 'successful';[void][IO.Directory]::CreateDirectory($workspace)
        $result=Export-WsmDeveloperProbe -Workspace $workspace -Role Source -Origin 'http://127.0.0.1:54321' -CollectorAdapter @{PlatformIdentity=$adapter;CommandsModules=$adapter;LocalVolumes=$adapter;NativeInventory=$adapter;HttpProbe=$adapter}
        Assert-DeveloperProbe ($result.Status -eq 'Completed') ('The complete adapter run did not produce a completed package: '+($result.CollectorResults|ConvertTo-Json -Depth 8 -Compress))
        Assert-DeveloperProbe ([IO.File]::Exists($result.Path) -and [IO.File]::Exists($result.HtmlPath)) 'The probe archive or local HTML summary is missing.'
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip=[IO.Compression.ZipFile]::OpenRead($result.Path)
        try{
            $names=@($zip.Entries|ForEach-Object FullName)
            Assert-DeveloperProbe (@('probe.json','index.html','files-index.json'|Where-Object {$_ -notin $names}).Count -eq 0) 'The ZIP is missing a required payload.'
            $indexStream=$zip.GetEntry('files-index.json').Open();$reader=New-Object IO.StreamReader($indexStream)
            try{$indexText=$reader.ReadToEnd();$parsedIndex=ConvertFrom-Json -InputObject $indexText;$index=if($parsedIndex -is [array]){$parsedIndex}else{@($parsedIndex)}}finally{$reader.Dispose()}
            foreach($entry in $index){
                $payload=$zip.GetEntry([string]$entry.Path);Assert-DeveloperProbe ($null -ne $payload) ('Indexed entry is missing: '+$entry.Path)
                $stream=$payload.Open();$memory=New-Object IO.MemoryStream
                try{$stream.CopyTo($memory);$bytes=$memory.ToArray()}finally{$stream.Dispose();$memory.Dispose()}
                $hash=(New-Object Security.Cryptography.SHA256Managed).ComputeHash($bytes);$actual=([BitConverter]::ToString($hash)).Replace('-','').ToLowerInvariant()
                Assert-DeveloperProbe ($actual -ceq [string]$entry.SHA256) ('ZIP entry hash mismatch: '+$entry.Path)
                Assert-DeveloperProbe ($bytes.Length -eq [long]$entry.Length) ('ZIP entry length mismatch: '+$entry.Path)
            }
            foreach($entry in @($zip.Entries)){$stream=$entry.Open();$reader=New-Object IO.StreamReader($stream);try{$text=$reader.ReadToEnd()}finally{$reader.Dispose()};Assert-DeveloperProbe (-not $text.Contains($secret)) ('Sensitive sentinel leaked through '+$entry.FullName)}
            $jsonStream=$zip.GetEntry('probe.json').Open();$jsonReader=New-Object IO.StreamReader($jsonStream);try{$probe=$jsonReader.ReadToEnd()|ConvertFrom-Json}finally{$jsonReader.Dispose()}
            Assert-DeveloperProbe ($probe.FormatVersion -eq '1.0' -and $probe.DataModel -eq 'SanitizedDeveloperProbeProjection' -and $probe.ToolVersion -eq '0.4.0' -and $probe.ToolFingerprint -match '^[a-f0-9]{64}$' -and $probe.ToolFingerprint -ceq $expectedToolFingerprint -and $probe.Mode -eq 'ReadOnly' -and -not $probe.ProductionQualified -and -not $probe.BusinessValidated) ('The format, exact release fingerprint, or qualification boundary is wrong. fingerprint='+$probe.ToolFingerprint+' expected='+$expectedToolFingerprint+' version='+$probe.ToolVersion+' format='+$probe.FormatVersion)
            Assert-DeveloperProbe ($probe.ResourceLimits.MaximumOutputBytes -eq 4194304 -and $probe.ResourceLimits.RawEvidenceBudgetBytes -ge 16777216) 'The serialized and local raw evidence budgets were not reported.'
            Assert-DeveloperProbe (@($probe.Collectors|Where-Object Id -eq NativeInventory).Count -eq 1) 'Native inventory was omitted from the manifest results.'
            $platformData=(@($probe.Collectors|Where-Object Id -eq PlatformIdentity)[0]).Data
            Assert-DeveloperProbe ($platformData.HostName -match '^\[host-[a-f0-9]{12}\]$' -and $platformData.OtherHostName -match '^\[host-[a-f0-9]{12}\]$' -and $platformData.HostName -ne $platformData.OtherHostName) 'Host identifiers were not anonymized as distinct stable aliases.'
            Assert-DeveloperProbe ($platformData.Credential.Redacted -and $platformData.Credential.OriginalType -eq 'PSCustomObject' -and $platformData.Credential.PropertyCount -eq 4 -and @($platformData.Credential.Properties|Where-Object {$_.Name -eq 'Enabled' -and $_.OriginalType -eq 'Boolean'}).Count -eq 1 -and @($platformData.Credential.Properties|Where-Object {$_.Name -eq 'RetryCount' -and $_.OriginalType -eq 'Int32'}).Count -eq 1 -and $platformData.PrivateKeyMaterial.Redacted -and $platformData.PrivateKeyMaterial.OriginalType -eq 'Array' -and $platformData.PrivateKeyMaterial.Count -eq 3 -and @($platformData.PrivateKeyMaterial.ElementTypes|Where-Object {$_ -in @('String','Int32','Boolean')}).Count -eq 3) 'Sensitive object or array redaction lost type and bounded shape metadata.'
            $nativeData=(@($probe.Collectors|Where-Object Id -eq NativeInventory)[0]).Data
            Assert-DeveloperProbe ($nativeData.Items.Count -eq 1 -and $nativeData.Items[0].Kind -eq 'WindowsService' -and $nativeData.Items[0].Version -eq '1.2' -and $nativeData.Items[0].Status -eq 'Success' -and $nativeData.Items[0].Dependencies[0] -eq 'Tcpip') 'Sanitized inventory item structure or useful fields were omitted.'
            Assert-DeveloperProbe ($nativeData.SoftwareCatalog.Entries[0].DisplayName -eq 'Example Runtime' -and $nativeData.SoftwareCatalog.Entries[0].Version -eq '3.4.5' -and $nativeData.SoftwareCatalog.Coverage[0].Status -eq 'Success') 'Sanitized software catalog structure was omitted.'
            Assert-DeveloperProbe ($nativeData.WorkloadDiscovery.References[0].ReferenceKind -eq 'IISBinding' -and $nativeData.WorkloadDiscovery.References[0].Path -match '^\[path-[a-f0-9]{12}\]$' -and -not $nativeData.WorkloadDiscovery.Complete) 'Sanitized workload discovery structure or path anonymization was omitted.'
            Assert-DeveloperProbe ($nativeData.ToolFingerprint.HostName -match '^\[host-[a-f0-9]{12}\]$' -and $nativeData.ToolFingerprint.MachineGuid -match '^\[host-[a-f0-9]{12}\]$' -and $nativeData.Source.Fingerprint -match '^\[host-[a-f0-9]{12}\]$') 'Machine fingerprints or identifiers were not anonymized.'
            Assert-DeveloperProbe ($nativeData.Source.Name -eq $platformData.HostName) 'Platform and native inventory host names did not share the same package alias.'
            $volumeData=(@($probe.Collectors|Where-Object Id -eq LocalVolumes)[0]).Data.Volumes
            Assert-DeveloperProbe ($volumeData[0].Path -eq $volumeData[1].Path -and $volumeData[0].Path -ne $volumeData[2].Path) 'Path aliases did not preserve same-path identity and different-path separation.'
            $htmlStream=$zip.GetEntry('index.html').Open();$htmlReader=New-Object IO.StreamReader($htmlStream);try{$html=$htmlReader.ReadToEnd()}finally{$htmlReader.Dispose()}
            Assert-DeveloperProbe ($html.Contains('開發者環境探測') -and $html.Contains('讀取示例')) 'The Chinese HTML report or ZIP reading example is missing.'
        }finally{$zip.Dispose()}

        $failing=Join-Path $Root 'failing';[void][IO.Directory]::CreateDirectory($failing)
        $failAdapter={param($CollectorId,$Context) if($CollectorId -eq 'LocalVolumes'){throw 'failure password="two words DEVPROBE_SENTINEL_7f8c" in C:\Users\private user\DEVPROBE_SENTINEL_7f8c.xml'};[pscustomobject]@{Status='Completed';Value='ok'}}
        $failureResult=Export-WsmDeveloperProbe -Workspace $failing -CollectorAdapter @{PlatformIdentity=$failAdapter;CommandsModules=$failAdapter;LocalVolumes=$failAdapter;NativeInventory=$failAdapter}
        Assert-DeveloperProbe ($failureResult.Status -eq 'Partial' -and $failureResult.CollectorCounts.Failed -eq 1) 'A failing collector did not produce an accurate partial result.'
        $failureRow=@($failureResult.CollectorResults|Where-Object Id -eq LocalVolumes)[0]
        Assert-DeveloperProbe ($failureRow.Data.ErrorType -and -not $failureRow.Data.ErrorSummary.Contains($secret) -and $failureRow.Data.ErrorSummary.Contains('[path-')) 'A sanitized collector error lost its type/path alias or leaked its secret.'
        $failZip=[IO.Compression.ZipFile]::OpenRead($failureResult.Path);try{$entry=$failZip.GetEntry('probe.json');$stream=$entry.Open();$reader=New-Object IO.StreamReader($stream);try{$failureJson=$reader.ReadToEnd()}finally{$reader.Dispose()};Assert-DeveloperProbe (-not $failureJson.Contains($secret)) 'Collector failure text leaked into the report.'}finally{$failZip.Dispose()}

        $timeout=Join-Path $Root 'timeout';[void][IO.Directory]::CreateDirectory($timeout)
        $slow={param($CollectorId,$Context) if($CollectorId -eq 'LocalVolumes'){Start-Sleep -Seconds 4};[pscustomobject]@{Status='Completed'}}
        $timeoutResult=Export-WsmDeveloperProbe -Workspace $timeout -CollectorTimeoutSeconds 1 -CollectorAdapter @{PlatformIdentity=$slow;CommandsModules=$slow;LocalVolumes=$slow;NativeInventory=$slow}
        Assert-DeveloperProbe ($timeoutResult.Status -eq 'Partial' -and $timeoutResult.CollectorCounts.TimedOut -eq 1) 'A slow collector did not time out cleanly.'

        $large=Join-Path $Root 'large';[void][IO.Directory]::CreateDirectory($large)
        $big={param($CollectorId,$Context) if($CollectorId -eq 'CommandsModules'){return [pscustomobject]@{Payload=('A'*40000)}};[pscustomobject]@{Status='Completed'}}
        $largeResult=Export-WsmDeveloperProbe -Workspace $large -MaximumOutputBytes 16384 -CollectorAdapter @{PlatformIdentity=$big;CommandsModules=$big;LocalVolumes=$big;NativeInventory=$big}
        Assert-DeveloperProbe ($largeResult.Status -eq 'Partial' -and $largeResult.CollectorCounts.Partial -eq 1 -and @($largeResult.CollectorResults|Where-Object ReasonCode -eq CollectorValueTruncated).Count -eq 1) 'Large collector output was not bounded and reported.'

        $rawBudget=Join-Path $Root 'raw-budget';[void][IO.Directory]::CreateDirectory($rawBudget)
        $rawWriter={param($CollectorId,$Context) if($CollectorId -eq 'NativeInventory'){$path=Join-Path $Context.RawRoot 'fixture.bin';$stream=[IO.File]::Open($path,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::Read);try{$buffer=New-Object byte[] (1024*1024);for($i=0;$i -lt 20;$i++){$stream.Write($buffer,0,$buffer.Length);$stream.Flush();Start-Sleep -Milliseconds 60}}finally{$stream.Dispose()};return [pscustomobject]@{Status='Completed'}};[pscustomobject]@{Status='Completed'}}
        $rawBudgetResult=Export-WsmDeveloperProbe -Workspace $rawBudget -MaximumOutputBytes 16384 -CollectorTimeoutSeconds 30 -CollectorAdapter @{PlatformIdentity=$rawWriter;CommandsModules=$rawWriter;LocalVolumes=$rawWriter;NativeInventory=$rawWriter}
        $rawBudgetRow=@($rawBudgetResult.CollectorResults|Where-Object Id -eq NativeInventory)[0]
        Assert-DeveloperProbe ($rawBudgetRow.Status -eq 'Partial' -and $rawBudgetRow.ReasonCode -eq 'RawEvidenceBudgetExceeded' -and $rawBudgetRow.Data.ObservedBytes -gt $rawBudgetRow.Data.BudgetBytes) 'Native raw evidence exceeded its budget without stopping and reporting partial status.'

        $cancelRoot=Join-Path $Root 'cancel';[void][IO.Directory]::CreateDirectory($cancelRoot)
        $operation=[Guid]::NewGuid().ToString();$token=New-WsmDeveloperProbeCancellationToken -Workspace $cancelRoot -OperationId $operation
        $requested= Request-WsmDeveloperProbeCancellation -CancellationToken $token
        Assert-DeveloperProbe ($requested.Kind -eq 'DeveloperProbeCancellationRequest' -and $requested.OperationId -eq $operation) 'The diagnostic cancellation helper did not write its operation-bound marker.'
        Remove-Item -LiteralPath $token.RequestPath -Force
        $marker=[pscustomobject]@{Kind='DeveloperProbeCancellationRequest';OperationId=$operation;RequestedUtc=[DateTime]::UtcNow.ToString('o')}
        $markerJson=$marker|ConvertTo-Json -Compress
        $markerPath=$token.RequestPath
        $markerLiteral="'"+$markerPath.Replace("'","''")+"'"
        $jsonLiteral="'"+$markerJson.Replace("'","''")+"'"
        $cancelSlow=[scriptblock]::Create("param(`$CollectorId,`$Context) if(`$CollectorId -eq 'PlatformIdentity'){[IO.File]::WriteAllText($markerLiteral,$jsonLiteral);Start-Sleep -Seconds 5};[pscustomobject]@{Status='Completed'}")
        $cancelResult=Export-WsmDeveloperProbe -Workspace $cancelRoot -CancellationToken $token -CollectorTimeoutSeconds 10 -CollectorAdapter @{PlatformIdentity=$cancelSlow;CommandsModules=$cancelSlow;LocalVolumes=$cancelSlow;NativeInventory=$cancelSlow}
        Assert-DeveloperProbe ($cancelResult.Status -eq 'Cancelled' -and $cancelResult.CollectorCounts.Cancelled -ge 1 -and @($cancelResult.CollectorResults|Where-Object {$_.Id -eq 'PlatformIdentity' -and $_.ReasonCode -eq 'CancellationRequested'}).Count -eq 1) 'Cancellation did not stop the active worker and preserve its status.'
        Write-Host 'PASS: developer probe ZIP, entry hashes, inventory structure, secret redaction, raw/serialized budgets, failure, timeout and cancellation.'
    } $root $helper
}finally{if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force}}
