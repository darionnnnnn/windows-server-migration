#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\src\ServiceIdentity.ps1')
$script:adReady=$true;$script:adTestCalls=0;$script:adRetrieveCalls=0;$script:nativeCalls=0;$script:nativeCallback=$null
function Test-ADServiceAccount {[CmdletBinding()]param([Parameter(Mandatory)][string]$Identity);$script:adTestCalls++;$script:lastAdIdentity=$Identity;$script:adReady}
function Get-ADServiceAccount {$script:adRetrieveCalls++;throw 'Account retrieval is forbidden in this fixture.'}
function Resolve-WsmAccountSid([string]$Account){switch -CaseSensitive ($Account){'DOMAIN\service-user'{'S-1-5-21-1-2-3-1001'};'DOMAIN\alias-user'{'S-1-5-21-1-2-3-1001'};default{throw ('Unknown test account '+$Account)}}}
function Assert-Throws([scriptblock]$Action,[string]$MessagePattern,[string]$Context){$caught=$null;try{& $Action}catch{$caught=$_};if(-not $caught){throw ($Context+': expected rejection')};if($MessagePattern -and $caught.Exception.Message -notmatch $MessagePattern){throw ($Context+': unexpected rejection: '+$caught.Exception.Message)};$caught}

# Built-in aliases normalize by their well-known SID and need no stored/prompted secret.
foreach($case in @(
    @{Input='LocalSystem';Canonical='NT AUTHORITY\SYSTEM';Sid='S-1-5-18';Mode='KnownLocalSystem'},
    @{Input='NT AUTHORITY\SYSTEM';Canonical='NT AUTHORITY\SYSTEM';Sid='S-1-5-18';Mode='KnownLocalSystem'},
    @{Input='S-1-5-19';Canonical='NT AUTHORITY\LocalService';Sid='S-1-5-19';Mode='BuiltinLocalService'},
    @{Input='NetworkService';Canonical='NT AUTHORITY\NetworkService';Sid='S-1-5-20';Mode='BuiltinNetworkService'})){
    $desired=[pscustomobject]@{Account=$case.Input};$spec=[pscustomobject]@{Owner='Fixture owner';Evidence='reviewed builtin account'};$policy=Get-WsmServiceAccountPolicy $desired $spec
    if($policy.CanonicalAccount -cne $case.Canonical -or $policy.AccountSid -cne $case.Sid -or $policy.Mode -cne $case.Mode -or $policy.NeededSecret){throw ('Well-known service account did not normalize: '+$case.Input)}
    $credentialPlan=Get-WsmServiceAccountCredential $desired $spec @{};if($credentialPlan.Credential -isnot [Management.Automation.PSCredential] -or $credentialPlan.Credential.UserName -cne $case.Canonical -or $credentialPlan.Credential.GetNetworkCredential().Password -cne ''){throw ('Built-in account did not receive an empty in-memory credential: '+$case.Input)}
}
$badSpec=[pscustomobject]@{Owner='Fixture owner';Evidence='reviewed'};Assert-Throws {Get-WsmServiceAccountPolicy ([pscustomobject]@{Account='NT AUTHORITY\LocalService'}) ([pscustomobject]@{AccountMode='UserPassword';SecretRef='x';Owner='Fixture owner'})} 'conflicts' 'Builtin mode mismatch' | Out-Null

# A trailing dollar sign is retained for review; it is not proof of an MSA or preflight eligibility.
$dollarDesired=[pscustomobject]@{Account='DOMAIN\worker$'};$dollarSpec=[pscustomobject]@{Owner='Fixture owner';Evidence='inventory source'};$dollarPolicy=Get-WsmServiceAccountPolicy $dollarDesired $dollarSpec
if($dollarPolicy.Mode -cne 'ReviewRequired' -or $dollarPolicy.NeededSecret -ne $true -or $dollarPolicy.RequiresTargetPreflight){throw 'A source account $ suffix was treated as verified managed-account identity.'}
Assert-Throws {Get-WsmServiceAccountCredential $dollarDesired $dollarSpec @{}} 'ReviewRequired|unsupported' 'Unqualified dollar account credential' | Out-Null

# User-password mode requires an explicit owner SecretRef and exact username or SID match.
$userDesired=[pscustomobject]@{Account='DOMAIN\service-user'};$userSpec=[pscustomobject]@{AccountMode='UserPassword';Owner='Fixture owner';Evidence='approved account review';SecretRef='service-secret'}
$secure=New-Object Security.SecureString;foreach($character in 'fixture-secret'.ToCharArray()){$secure.AppendChar($character)};$userCredential=New-Object Management.Automation.PSCredential('domain\SERVICE-USER',$secure);$secrets=@{'service-secret'=$userCredential}
$userPlan=Get-WsmServiceAccountCredential $userDesired $userSpec $secrets;if(-not $userPlan.NeededSecret -or $userPlan.Credential -ne $userCredential -or $userPlan.PasswordMode -cne 'SecretRef'){throw 'User credential was not retained as the exact in-memory PSCredential.'}
$directPolicy=Get-WsmServiceAccountPolicy $userDesired $userSpec;if($directPolicy.SecretRef -cne 'service-secret'){throw 'UserPassword policy omitted its owner SecretRef for direct credential resolution.'};$directPlan=New-WsmServiceAccountCredential $directPolicy $secrets;if($directPlan.Credential -ne $userCredential){throw 'Direct policy-to-credential path lost the owner SecretRef.'}
$aliasCredential=New-Object Management.Automation.PSCredential('DOMAIN\alias-user',$secure);$sidPlan=New-WsmServiceAccountCredential $userPlan.Policy @{ 'service-secret'=$aliasCredential };if($sidPlan.Credential -ne $aliasCredential){throw 'SID-equivalent credential identity was rejected.'}
Assert-Throws {Get-WsmServiceAccountCredential $userDesired ([pscustomobject]@{AccountMode='UserPassword';Owner='Fixture owner';Evidence='reviewed';SecretRef='missing'}) $secrets} 'unavailable' 'Missing owner secret' | Out-Null
Assert-Throws {Get-WsmServiceAccountCredential $userDesired ([pscustomobject]@{AccountMode='UserPassword';Owner='Fixture owner';Evidence='reviewed'}) $secrets} 'SecretRef' 'Missing SecretRef' | Out-Null
Assert-Throws {Get-WsmServiceAccountCredential $userDesired $userSpec @{ 'service-secret'=(New-Object Management.Automation.PSCredential('DOMAIN\other-user',$secure)) }} 'username/SID' 'Credential identity mismatch' | Out-Null
Assert-Throws {Get-WsmServiceAccountPolicy ([pscustomobject]@{Account='DOMAIN\worker'}) ([pscustomobject]@{AccountMode='Guess';Owner='Fixture owner';SecretRef='x'})} 'UserPassword|ManagedServiceAccount' 'Unverified account mode' | Out-Null
Assert-Throws {Get-WsmServiceAccountPolicy ([pscustomobject]@{Account='fixturemsa$'}) ([pscustomobject]@{AccountMode='ManagedServiceAccount';ManagedAccountEvidence='reviewed'})} 'qualified DOMAIN' 'Managed account must be domain-qualified' | Out-Null

# MSA eligibility is a target-local, read-only Test-ADServiceAccount preflight. No Get-ADServiceAccount or installation occurs.
$msaDesired=[pscustomobject]@{Name='FixtureManaged';DisplayName='Fixture 管理服務';BinaryPathName='C:\Fixture\managed service.exe';Account='DOMAIN\fixturemsa$';Dependencies=@('FixtureBase','+FixtureServiceGroup');Description='Unicode 描述'}
$msaSpec=[pscustomobject]@{AccountMode='ManagedServiceAccount';ManagedAccountEvidence='approved gMSA readiness evidence';Owner='Fixture owner';Evidence='fixture reviewed'}
Assert-Throws {Get-WsmServiceAccountPolicy $msaDesired ([pscustomobject]@{AccountMode='ManagedServiceAccount';Owner='Fixture owner'})} 'ManagedAccountEvidence' 'Missing managed account evidence' | Out-Null
$script:adReady=$false;Assert-Throws {Get-WsmServiceAccountCredential $msaDesired $msaSpec @{}} 'not currently eligible' 'Target MSA eligibility failure' | Out-Null;if($script:nativeCalls -ne 0){throw 'MSA preflight failure reached native create callback.'}
$script:adReady=$true;$msaCredentials=Get-WsmServiceAccountCredential $msaDesired $msaSpec @{};if($script:lastAdIdentity -cne 'fixturemsa$' -or $msaCredentials.Credential -or -not $msaCredentials.NativePasswordPointerIsNull -or $msaCredentials.PasswordMode -cne 'NullRequired'){throw 'Managed account did not preserve the NULL-password native contract.'}

# Compile the Unicode P/Invoke wrapper, but inject a native callback so no SCM handle or service is ever opened.
Initialize-WsmServiceIdentityNative;$nativeType='WsmServiceIdentityNative' -as [type];if(-not $nativeType){throw 'Native service interop type was not compiled.'}
$createMethod=$nativeType.GetMethod('CreateServiceW',[Reflection.BindingFlags]'NonPublic,Static');$dll=[Runtime.InteropServices.DllImportAttribute]($createMethod.GetCustomAttributes([Runtime.InteropServices.DllImportAttribute],$false)[0]);$parameters=$createMethod.GetParameters()
if(-not $dll -or $dll.EntryPoint -cne 'CreateServiceW' -or $dll.CharSet -ne [Runtime.InteropServices.CharSet]::Unicode -or -not $dll.SetLastError -or $parameters[-1].ParameterType -ne [IntPtr]){throw 'CreateServiceW signature is not Unicode/SetLastError with an explicit native password pointer.'}
$script:WsmServiceIdentityNativeCallback={param($Request)$script:nativeCalls++;if($Request.Name -cne 'FixtureManaged' -or $Request.DisplayName -cne 'Fixture 管理服務' -or $Request.BinaryPathName -cne 'C:\Fixture\managed service.exe' -or $Request.Account -cne 'DOMAIN\fixturemsa$'){throw 'Native callback received altered Unicode identity/configuration.'};if($Request.ServiceTypeValue -ne 16 -or $Request.StartTypeValue -ne 4 -or $Request.StartType -cne 'Disabled' -or $Request.PasswordPointer -ne [IntPtr]::Zero -or -not $Request.PasswordMustBeNull){throw 'Managed native request must use disabled own-process and NULL password.'};$multi=(-join $Request.DependenciesMultiSz);$expected="FixtureBase`0+FixtureServiceGroup`0`0";if($multi -cne $expected){throw ('Native callback received malformed dependency MULTI_SZ: '+$multi.Replace([char]0,'|'))};if($Request.Description -cne 'Unicode 描述'){throw 'Unicode service description was altered.'};[pscustomobject]@{Created=$true;ServiceName=$Request.Name;TestNativeCallback=$true}}
$created=New-WsmManagedService $msaDesired $msaSpec;if(-not $created.Created -or $created.NativeResult.ServiceName -cne 'FixtureManaged' -or $script:nativeCalls -ne 1){throw 'Managed service helper did not pass its reviewed request to the injected native callback.'}
$multiBuilder=ConvertTo-WsmServiceDependencyMultiSz @('FixtureBase','+FixtureServiceGroup');if((-join $multiBuilder.Characters) -cne "FixtureBase`0+FixtureServiceGroup`0`0" -or $multiBuilder.Characters[-1] -ne [char]0 -or $multiBuilder.Characters[-2] -ne [char]0){throw 'PowerShell service dependency MULTI_SZ is not double-null terminated.'}
$emptyMultiBuilder=ConvertTo-WsmServiceDependencyMultiSz @();if($emptyMultiBuilder.Characters.Length -ne 0){throw 'A service with no dependencies must pass a NULL dependency pointer, not a malformed one-null MULTI_SZ.'}
$script:WsmServiceIdentityNativeCallback={param($Request)$script:nativeCalls++;throw (New-Object ComponentModel.Win32Exception(1069,'Injected native logon failure'))};$nativeFailure=$null;try{New-WsmManagedService $msaDesired $msaSpec | Out-Null}catch{$nativeFailure=$_.Exception};if(-not $nativeFailure -or $nativeFailure.NativeErrorCode -ne 1069){throw 'Native Win32 exception code was not preserved through managed creation.'}
$script:WsmServiceIdentityNativeCallback={param($Request)$script:nativeCalls++;[IntPtr]::Zero};Assert-Throws {New-WsmManagedService $msaDesired $msaSpec} 'null handle' 'Native null-handle failure' | Out-Null
$script:WsmServiceIdentityNativeCallback={param($Request)$script:nativeCalls++;$null};Assert-Throws {New-WsmManagedService $msaDesired $msaSpec} 'returned failure' 'Missing native create result' | Out-Null
if($script:adRetrieveCalls -ne 0){throw 'Fixture unexpectedly retrieved an Active Directory account object or password.'}
$script:WsmServiceIdentityNativeCallback=$null
Write-Host ('PASS: typed service account normalization and gating; owner SecretRef username/SID binding; explicit read-only target MSA preflight; gMSA NULL native password contract; bounded Unicode CreateServiceW declaration; disabled own-process request; service/group MULTI_SZ; native Win32 failure propagation. AD retrieval/installation and SCM APIs were never called.')
