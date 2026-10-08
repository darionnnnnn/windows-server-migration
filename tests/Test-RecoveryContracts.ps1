#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-recovery-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
Initialize-WsmWorkspace $root | Out-Null
$source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='fixture'}
$item=New-WsmItem $source.HostId Services Service 'Fixture' 'fixture' @{Name='Fixture';StartMode='Auto';PathName='C:\fixture.exe'}
$path=Join-Path $root 'input.json';$inv=New-WsmInventory $source 1 @($item);[IO.File]::WriteAllText($path,($inv | ConvertTo-Json -Depth 20))
$c=Import-WsmInventory $root $path (Get-FileHash $path).Hash 'target'
& $module {
    $script:originalRecoveryWriter=(Get-Command Write-WsmJson).ScriptBlock;$script:failFleet=$true
    function script:Write-WsmJson {param($Path,$Data) if($script:failFleet -and [IO.Path]::GetFileName($Path) -eq 'fleet.json' -and [IO.Path]::GetDirectoryName($Path) -eq $script:recoveryRoot){throw 'Injected disk failure at fleet commit'};& $script:originalRecoveryWriter $Path $Data}
    $script:recoveryRoot=$args[0]
} $root
$inv.Revision=2;$inv.Source.Name='fixture-renamed';[IO.File]::WriteAllText($path,($inv | ConvertTo-Json -Depth 20));$blocked=$false
try{Import-WsmInventory $root $path (Get-FileHash $path).Hash | Out-Null}catch{$blocked=$true};if(-not $blocked){throw 'Fixture did not interrupt transaction'}
$blocked=$false;try{Get-WsmFleet $root | Out-Null}catch{$blocked=$true};if(-not $blocked){throw 'Inconsistent workspace was exposed as complete'}
& $module {$script:failFleet=$false}
Repair-WsmWorkspace $root | Out-Null
if((Get-WsmCatalog $root $c.PairId).InventoryRevision -ne 2 -or (Test-Path (Join-Path $root 'workspace-transaction.json'))){throw 'Workspace transaction failed to recover'}
& $module {
    $before=[pscustomobject]@{ItemId=('a'*64);Kind='Service';NaturalKey='Fixture';Settings=@{Name='Fixture';StartMode='Auto';PathName='C:\old.exe'};SettingsHash='old'}
    $after=[pscustomobject]@{ItemId=$before.ItemId;Kind='Service';NaturalKey='Fixture';Settings=@{Name='Fixture';StartMode='Disabled';PathName='C:\old.exe'};SettingsHash='new'}
    $activity=@([pscustomobject]@{ItemId=$before.ItemId;Kind='Service';Name='Fixture';State='DisabledStopped'})
    Assert-WsmQuiescenceChange $before $after $activity
    $after.Settings.PathName='C:\changed.exe';$blocked=$false;try{Assert-WsmQuiescenceChange $before $after $activity}catch{$blocked=$true};if(-not $blocked){throw 'Freeze blessed unrelated configuration drift'}
    function script:Resolve-WsmAccountSid {param($Account) 'S-1-5-21-1-2-3-1001'}
    $plan=[pscustomobject]@{IdentityMap=[pscustomobject]@{Mappings=@([pscustomobject]@{SourceSid='S-1-5-21-4-5-6-1001';TargetAccount='TARGET\fixture';ExpectedTargetSid='S-1-5-21-1-2-3-1001';CreatedByItemId='';Owner='fixture';Evidence='approved'})}}
    $map=Resolve-WsmIdentityMap $plan;if($map.Count -ne 1){throw 'Approved identity map lost'}
    $acl='O:SYG:SYD:(A;OICIID;FA;;;SY)';$upgraded='O:SYG:SYD:AI(A;OICIID;FA;;;SY)'
    if(Test-WsmSddlMatch $acl $upgraded){throw 'Exact ACL mode ignored control flags'}
    if(-not (Test-WsmSddlMatch $acl $upgraded AllowAutoInheritedUpgrade)){throw 'Reviewed one-way auto-inheritance conversion failed'}
    foreach($different in @('O:BAG:SYD:AI(A;OICIID;FA;;;SY)','O:SYG:SYD:PAI(A;OICIID;FA;;;SY)','O:SYG:SYD:AI(A;OICIID;FR;;;SY)','O:SYG:SYD:AI(A;OICI;FA;;;SY)')){if(Test-WsmSddlMatch $acl $different AllowAutoInheritedUpgrade){throw 'ACL normalization weakened owner/protection/rights/inherited-ACE verification'}}
    if(Test-WsmSddlMatch $upgraded $acl AllowAutoInheritedUpgrade){throw 'ACL auto-inheritance downgrade allowed'}
    $blocked=$false;try{Resolve-WsmIdentityMap $plan @{'S-1-5-21-4-5-6-1001'='S-1-5-32-544'} | Out-Null}catch{$blocked=$true};if(-not $blocked){throw 'Unapproved runtime ACL privilege mapping allowed'}
    $provider=[Guid]::NewGuid().ToString();$dependencyPlan=[pscustomobject]@{CrossHostDependencies=@([pscustomobject]@{PairId=$provider;Type='Mandatory'})}
    $blocked=$false;try{Assert-WsmDependencyReceipts $dependencyPlan @()}catch{$blocked=$true};if(-not $blocked){throw 'Cross-host prerequisite ignored'}
    $receipt=[pscustomobject]@{IndependentHash=('b'*64);Result=[pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='StageResult';PairId=$provider;Stage='Cutover';Status='Succeeded';Mode='IsolatedPilot';ProductionVerified=$false;ManifestHash=('c'*64);PayloadGeneration=2;ProducedUtc=(Get-WsmUtc)}}
    Assert-WsmDependencyReceipts $dependencyPlan @($receipt);$receipt.Result.ProducedUtc=[DateTime]::UtcNow.AddDays(-2).ToString('o');$blocked=$false;try{Assert-WsmDependencyReceipts $dependencyPlan @($receipt)}catch{$blocked=$true};if(-not $blocked){throw 'Stale provider receipt unlocked cutover'}
    $reader=New-Object IO.StringReader(('a'*100000)+'`n');$blocked=$false;try{Read-WsmBoundedLines $reader -MaximumCharacters 4096 | Out-Null}catch{$blocked=$true}finally{$reader.Dispose()};if(-not $blocked){throw 'Oversized artifact/journal line accepted'}
}
& $module {
    param($Root)
    $pair=[Guid]::NewGuid().ToString();$ids=@(('1'*64),('2'*64),('3'*64));$planItems=@(foreach($id in $ids){[pscustomobject]@{ItemId=$id;MigrationSpec=[pscustomobject]@{Adapter='Service';Desired=[pscustomobject]@{Name=$id}}}})
    $script:adapterRecoveryPackage=[pscustomobject]@{Manifest=[pscustomobject]@{PairId=$pair;BatchId=[Guid]::NewGuid().ToString();Target=[pscustomobject]@{Fingerprint=('b'*64)};PlanHash=('d'*64)};Plan=[pscustomobject]@{Items=$planItems}}
    function script:Test-WsmMigrationPackage {param($ManifestPath,$ExpectedHash)$script:adapterRecoveryPackage}
    function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=('b'*64);IsServer=$true;Administrator=$true;Is64Bit=$true}}
    function script:Get-WsmAdapterState {param($Spec)[pscustomobject]@{Exists=($Spec.Desired.Name -cne ('2'*64))}}
    function script:Test-WsmAdapterConfiguration {param($Spec)[pscustomobject]@{Passed=($Spec.Desired.Name -cne ('3'*64));Actual=[pscustomobject]@{Exists=$true;State='Stopped'}}}
    $paths=Get-WsmOperationPaths $Root $pair;$state=Get-WsmOperationState $paths $script:adapterRecoveryPackage
    foreach($id in $ids){$intent=[pscustomobject]@{ItemId=$id;Phase='AdapterCreating';Adapter='Service';ManifestHash=('d'*64);AbsentBefore=$true;BeforeHash=('e'*64)};$state.PendingOperations+=@($intent);Add-WsmJournal $paths $state AdapterIntent $id $intent}
    $blocked=$false;try{Repair-WsmOperation 'fixture-only' ('d'*64) $Root | Out-Null}catch{$blocked=$true};if(-not $blocked){throw 'Drifting interrupted adapter was adopted'}
    $state=Read-WsmJson $paths.State;if($state.Items.Count -ne 1 -or $state.Items[0].ItemId -cne ('1'*64) -or $state.PendingOperations.Count -ne 1 -or $state.PendingOperations[0].ItemId -cne ('3'*64)){throw 'Adapter repair lost precise adopted/absent/drift ownership state'}
} (Join-Path $root 'adapter-fixture')
& $module {
    param($Root)
    $scope=Join-Path $Root 'business';$plan=[pscustomobject]@{Items=@([pscustomobject]@{Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=$scope;TargetPath=$scope}})}
    foreach($field in @('SourcePath','TargetPath')){foreach($workspace in @($scope,(Join-Path $scope 'state'),$Root)){$blocked=$false;try{Assert-WsmWorkspaceSeparation $plan $workspace $field}catch{$blocked=$true};if(-not $blocked){throw 'Scope/workspace equality or ancestor collision allowed'}};Assert-WsmWorkspaceSeparation $plan (Join-Path $Root 'business-state') $field}
} (Join-Path $root 'workspace-boundaries')
& $module {
    param($Root)
    $id='a'*64;$pair=[Guid]::NewGuid().ToString();$script:adapterRecoveryPackage=[pscustomobject]@{Manifest=[pscustomobject]@{PairId=$pair;BatchId=[Guid]::NewGuid().ToString();Target=[pscustomobject]@{Fingerprint=('b'*64)};PlanHash=('d'*64)};Plan=[pscustomobject]@{Items=@([pscustomobject]@{ItemId=$id;MigrationSpec=[pscustomobject]@{Adapter='WindowsFeature'}})}}
    function script:Get-WsmAdapterState {param($Spec)[pscustomobject]@{Exists=$true}}
    function script:Test-WsmAdapterConfiguration {param($Spec)[pscustomobject]@{Passed=$true;Actual=[pscustomobject]@{Exists=$true}}}
    function script:Get-WsmBootStamp {'original-boot'}
    $paths=Get-WsmOperationPaths $Root $pair;$state=Get-WsmOperationState $paths $script:adapterRecoveryPackage
    $intent=[pscustomobject]@{ItemId=$id;Phase='AdapterCreating';Adapter='WindowsFeature';ManifestHash=('d'*64);AbsentBefore=$true;BeforeHash=('e'*64);BootBefore='original-boot'};$state.PendingOperations=@($intent);Add-WsmJournal $paths $state AdapterIntent $id $intent
    $result=Repair-WsmOperation fixture ('d'*64) $Root
    if($result.State.Stage -cne 'RebootRequired' -or $result.State.Items[0].Status -cne 'RebootRequired' -or $result.State.Items[0].BootBefore -cne 'original-boot'){throw 'Interrupted feature install bypassed reboot barrier or lost durable boot baseline'}
} (Join-Path $root 'feature-interruption')
Write-Host ('PASS: interrupted workspace and adapter intent recovery; scope/workspace boundaries, drift guard, SID mapping, provider evidence and bounded index reader. Evidence: '+$root)
