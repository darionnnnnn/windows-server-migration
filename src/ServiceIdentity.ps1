Set-StrictMode -Version Latest

function Get-WsmServiceAccountPolicy($Desired,$Spec) {
    if(-not $Desired -or -not $Spec -or -not $Desired.PSObject.Properties['Account']){throw 'Service account policy requires reviewed desired account and service spec.'}
    $account=([string]$Desired.Account).Trim();if([string]::IsNullOrWhiteSpace($account) -or $account.Length -gt 256 -or $account -match '[\x00-\x1f]'){throw 'Service account name is empty or outside the supported bound.'}
    $canonical=$null;$sid=$null;$builtinMode=$null
    switch -Regex ($account) {
        '^(?i:LocalSystem|SYSTEM|NT AUTHORITY\\SYSTEM|S-1-5-18)$' {$canonical='NT AUTHORITY\SYSTEM';$sid='S-1-5-18';$builtinMode='KnownLocalSystem';break}
        '^(?i:LocalService|NT AUTHORITY\\LocalService|S-1-5-19)$' {$canonical='NT AUTHORITY\LocalService';$sid='S-1-5-19';$builtinMode='BuiltinLocalService';break}
        '^(?i:NetworkService|NT AUTHORITY\\NetworkService|S-1-5-20)$' {$canonical='NT AUTHORITY\NetworkService';$sid='S-1-5-20';$builtinMode='BuiltinNetworkService';break}
    }
    if($builtinMode){
        if($Spec.PSObject.Properties['AccountMode'] -and [string]$Spec.AccountMode -cne $builtinMode){throw 'Declared AccountMode conflicts with the well-known service-account SID.'}
        if($Spec.PSObject.Properties['SecretRef'] -and $Spec.SecretRef){throw 'Built-in service identities do not accept a password SecretRef.'}
        [pscustomobject][ordered]@{CanonicalAccount=$canonical;AccountSid=$sid;Mode=$builtinMode;NeededSecret=$false;RequiresTargetPreflight=$false;PreflightIdentity='';Reason='Well-known service-account SID'};return
    }
    if($Spec.PSObject.Properties['AccountMode'] -and [string]$Spec.AccountMode -ceq 'ManagedServiceAccount'){
        if($account -notmatch '^[A-Za-z0-9.-]{1,63}\\[A-Za-z0-9._-]{1,14}\$'){throw 'ManagedServiceAccount requires a qualified DOMAIN\sam$ account name.'}
        if(-not $Spec.PSObject.Properties['ManagedAccountEvidence'] -or [string]::IsNullOrWhiteSpace([string]$Spec.ManagedAccountEvidence)){throw 'Managed service account requires owner-reviewed ManagedAccountEvidence.'}
        $sam=$account;if($sam.Contains('\')){$sam=$sam.Substring($sam.LastIndexOf('\')+1)}
        [pscustomobject][ordered]@{CanonicalAccount=$account;AccountSid='';Mode='ManagedServiceAccount';NeededSecret=$false;RequiresTargetPreflight=$true;PreflightIdentity=$sam;Reason='Target Test-ADServiceAccount preflight required; native CreateServiceW lpPassword must be NULL'};return
    }
    if($account.EndsWith('$',[StringComparison]::Ordinal)){
        [pscustomobject][ordered]@{CanonicalAccount=$account;AccountSid='';Mode='ReviewRequired';NeededSecret=$true;RequiresTargetPreflight=$false;PreflightIdentity='';Reason='A $ suffix alone does not establish managed-account type or target eligibility'};return
    }
    if(-not $Spec.PSObject.Properties['AccountMode'] -or [string]$Spec.AccountMode -cne 'UserPassword'){throw 'Non-built-in service accounts require explicit AccountMode=UserPassword or ManagedServiceAccount.'}
    if(-not $Spec.PSObject.Properties['SecretRef'] -or [string]::IsNullOrWhiteSpace([string]$Spec.SecretRef) -or -not $Spec.PSObject.Properties['Owner'] -or [string]::IsNullOrWhiteSpace([string]$Spec.Owner)){throw 'UserPassword service accounts require an owner and an in-memory SecretRef.'}
    if($account -match '[\\/]{2}|[\*?\[\]]|^\\|\\$|^\.|\.$'){throw 'UserPassword account name is outside the supported exact account format.'}
    [pscustomobject][ordered]@{CanonicalAccount=$account;AccountSid='';Mode='UserPassword';NeededSecret=$true;SecretRef=[string]$Spec.SecretRef;RequiresTargetPreflight=$false;PreflightIdentity='';Reason='Owner-supplied credential is required only in memory'}
}
function Test-WsmServiceAccountTargetPreflight($Policy) {
    if(-not $Policy -or $Policy.Mode -ne 'ManagedServiceAccount' -or -not $Policy.RequiresTargetPreflight){throw 'Target account preflight accepts only an explicit managed service account policy.'}
    $command=Get-Command Test-ADServiceAccount -ErrorAction SilentlyContinue;if(-not $command){throw 'ActiveDirectory Test-ADServiceAccount is unavailable; do not install or retrieve the account automatically.'}
    $ready=$false;try{$ready=[bool](Test-ADServiceAccount -Identity $Policy.PreflightIdentity -ErrorAction Stop)}catch{throw ('Managed service account target preflight failed: '+$_.Exception.GetType().FullName)}
    if(-not $ready){throw ('Managed service account is not currently eligible on this target: '+$Policy.PreflightIdentity)}
    [pscustomobject]@{Passed=$true;Identity=$Policy.PreflightIdentity;Method='Test-ADServiceAccount';ReadOnly=$true;InstalledOrChanged=$false}
}
function New-WsmServiceAccountCredential($Policy,[hashtable]$Secrets=@{}) {
    if(-not $Policy){throw 'Service account policy is required.'}
    switch($Policy.Mode){
        {$_ -in @('KnownLocalSystem','BuiltinLocalService','BuiltinNetworkService')} {$password=New-Object Security.SecureString;$credential=New-Object Management.Automation.PSCredential([string]$Policy.CanonicalAccount,$password);[pscustomobject]@{Policy=$Policy;Credential=$credential;NeededSecret=$false;NativePasswordPointerIsNull=$false;PasswordMode='EmptyString'}}
        UserPassword {$secretRef=[string]$Policy.SecretRef;if(-not $secretRef -or -not $Secrets.ContainsKey($secretRef)){throw 'Owner-reviewed service SecretRef is unavailable from the in-memory credential map.'};$credential=$Secrets[$secretRef];if($credential -isnot [Management.Automation.PSCredential]){throw 'Service SecretRef must resolve to an in-memory PSCredential.'};$matchesName=([string]$credential.UserName -ieq [string]$Policy.CanonicalAccount);$matchesSid=$false;if(-not $matchesName){$resolver=Get-Command Resolve-WsmAccountSid -ErrorAction SilentlyContinue;if($resolver){try{$matchesSid=(Resolve-WsmAccountSid ([string]$credential.UserName)) -ceq (Resolve-WsmAccountSid ([string]$Policy.CanonicalAccount))}catch{$matchesSid=$false}}};if(-not $matchesName -and -not $matchesSid){throw 'In-memory credential username/SID does not match the reviewed service account.'};[pscustomobject]@{Policy=$Policy;Credential=$credential;NeededSecret=$true;NativePasswordPointerIsNull=$false;PasswordMode='SecretRef'}}
        ManagedServiceAccount {[pscustomobject]@{Policy=$Policy;Credential=$null;NeededSecret=$false;NativePasswordPointerIsNull=$true;PasswordMode='NullRequired'}}
        default {throw 'Service account is ReviewRequired or unsupported; no credential may be created.'}
    }
}
function Get-WsmServiceAccountCredential($Desired,$Spec,[hashtable]$Secrets=@{}) {
    $policy=Get-WsmServiceAccountPolicy $Desired $Spec
    if($policy.Mode -eq 'ManagedServiceAccount'){[void](Test-WsmServiceAccountTargetPreflight $policy)}
    $result=New-WsmServiceAccountCredential $policy $Secrets
    $result
}
function ConvertTo-WsmServiceDependencyMultiSz([string[]]$Dependencies) {
    $dependencies=@($Dependencies);if($dependencies.Count -gt 512){throw 'Service dependencies exceed the supported count of 512.'}
    if(-not $dependencies.Count){return [pscustomobject]@{Characters=(New-Object char[] 0);CharacterCount=0;Text=''}}
    $seen=@{};$charCount=1
    foreach($dependency in $dependencies){if([string]::IsNullOrWhiteSpace($dependency) -or $dependency.Length -gt 256 -or $dependency -match '[\x00-\x1f\\/]|\*|\?|\[|\]'){throw 'Invalid service dependency name.'};$key=$dependency.ToUpperInvariant();if($seen.ContainsKey($key)){throw 'Duplicate service dependency.'};$seen[$key]=$true;$charCount+=$dependency.Length+1}
    if($charCount -gt 32767){throw 'Service dependency MULTI_SZ exceeds the supported 32767 UTF-16 character bound.'}
    $buffer=New-Object char[] $charCount;$offset=0;foreach($dependency in $dependencies){$dependency.CopyTo(0,$buffer,$offset,$dependency.Length);$offset+=$dependency.Length;$buffer[$offset]=[char]0;$offset++};$buffer[$offset]=[char]0
    [pscustomobject]@{Characters=$buffer;CharacterCount=$charCount;Text=(-join $buffer)}
}
function Initialize-WsmServiceIdentityNative {
    if('WsmServiceIdentityNative' -as [type]){return}
    $source=@'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class WsmServiceIdentityNative
{
    private const uint SC_MANAGER_CONNECT = 0x0001;
    private const uint SC_MANAGER_CREATE_SERVICE = 0x0002;
    private const uint SERVICE_CHANGE_CONFIG = 0x0002;
    private const uint SERVICE_QUERY_CONFIG = 0x0001;
    private const uint SERVICE_WIN32_OWN_PROCESS = 0x00000010;
    private const uint SERVICE_DISABLED = 0x00000004;
    private const uint SERVICE_ERROR_NORMAL = 0x00000001;
    private const uint SERVICE_CONFIG_DESCRIPTION = 1;

    [StructLayout(LayoutKind.Sequential)]
    private struct SERVICE_DESCRIPTIONW { public IntPtr lpDescription; }

    [DllImport("advapi32.dll", EntryPoint="OpenSCManagerW", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
    private static extern IntPtr OpenSCManagerW(string machine, string database, uint access);

    [DllImport("advapi32.dll", EntryPoint="CreateServiceW", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
    private static extern IntPtr CreateServiceW(IntPtr manager, [MarshalAs(UnmanagedType.LPWStr)] string serviceName,
        [MarshalAs(UnmanagedType.LPWStr)] string displayName, uint access, uint serviceType, uint startType,
        uint errorControl, [MarshalAs(UnmanagedType.LPWStr)] string binaryPath,
        [MarshalAs(UnmanagedType.LPWStr)] string loadOrderGroup, IntPtr tagId, IntPtr dependencies,
        [MarshalAs(UnmanagedType.LPWStr)] string serviceStartName, IntPtr password);

    [DllImport("advapi32.dll", EntryPoint="ChangeServiceConfig2W", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
    private static extern bool ChangeServiceConfig2W(IntPtr service, uint infoLevel, IntPtr info);

    [DllImport("advapi32.dll", EntryPoint="CloseServiceHandle", SetLastError=true)]
    private static extern bool CloseServiceHandle(IntPtr handle);

    public static char[] BuildMultiSz(string[] dependencies)
    {
        if (dependencies == null || dependencies.Length == 0) return new char[0];
        if (dependencies.Length > 512) throw new ArgumentOutOfRangeException("dependencies");
        int length = 1;
        foreach (string dependency in dependencies)
        {
            if (String.IsNullOrWhiteSpace(dependency) || dependency.Length > 256 || dependency.IndexOf('\0') >= 0 || dependency.IndexOf('/') >= 0 || dependency.IndexOf('\\') >= 0)
                throw new ArgumentException("Invalid service dependency.", "dependencies");
            checked { length += dependency.Length + 1; }
        }
        if (length > 32767) throw new ArgumentOutOfRangeException("dependencies");
        char[] result = new char[length]; int offset = 0;
        foreach (string dependency in dependencies)
        {
            dependency.CopyTo(0, result, offset, dependency.Length); offset += dependency.Length;
            result[offset++] = '\0';
        }
        result[offset] = '\0';
        return result;
    }

    public static void CreateDisabledManagedService(string serviceName, string displayName, string binaryPath,
        string account, string[] dependencies, string description)
    {
        if (String.IsNullOrWhiteSpace(serviceName) || serviceName.Length > 256 || serviceName.IndexOf('/') >= 0 || serviceName.IndexOf('\\') >= 0 || serviceName.IndexOf('\0') >= 0)
            throw new ArgumentException("Invalid service name.", "serviceName");
        if (String.IsNullOrWhiteSpace(displayName) || displayName.Length > 256 || displayName.IndexOf('\0') >= 0)
            throw new ArgumentException("Invalid service display name.", "displayName");
        if (String.IsNullOrWhiteSpace(binaryPath) || binaryPath.Length > 32767 || binaryPath.IndexOf('\0') >= 0)
            throw new ArgumentException("Invalid service binary path.", "binaryPath");
        if (String.IsNullOrWhiteSpace(account) || account.Length > 256 || account.IndexOf('\0') >= 0)
            throw new ArgumentException("Invalid managed service account.", "account");
        char[] multiSz = BuildMultiSz(dependencies);
        IntPtr dependencyBuffer = IntPtr.Zero, manager = IntPtr.Zero, service = IntPtr.Zero, descriptionText = IntPtr.Zero, descriptionBuffer = IntPtr.Zero;
        try
        {
            if (multiSz.Length != 0)
            {
                dependencyBuffer = Marshal.AllocHGlobal(checked(multiSz.Length * sizeof(char)));
                Marshal.Copy(multiSz, 0, dependencyBuffer, multiSz.Length);
            }
            manager = OpenSCManagerW(null, null, SC_MANAGER_CONNECT | SC_MANAGER_CREATE_SERVICE);
            if (manager == IntPtr.Zero) { int error = Marshal.GetLastWin32Error(); throw new Win32Exception(error, "OpenSCManagerW failed."); }
            service = CreateServiceW(manager, serviceName, displayName, SERVICE_CHANGE_CONFIG | SERVICE_QUERY_CONFIG,
                SERVICE_WIN32_OWN_PROCESS, SERVICE_DISABLED, SERVICE_ERROR_NORMAL, binaryPath, null, IntPtr.Zero,
                dependencyBuffer, account, IntPtr.Zero);
            if (service == IntPtr.Zero) { int error = Marshal.GetLastWin32Error(); throw new Win32Exception(error, "CreateServiceW failed for the managed service account."); }
            if (!String.IsNullOrEmpty(description))
            {
                descriptionText = Marshal.StringToHGlobalUni(description);
                SERVICE_DESCRIPTIONW nativeDescription = new SERVICE_DESCRIPTIONW { lpDescription = descriptionText };
                int size = Marshal.SizeOf(typeof(SERVICE_DESCRIPTIONW)); descriptionBuffer = Marshal.AllocHGlobal(size);
                Marshal.StructureToPtr(nativeDescription, descriptionBuffer, false);
                if (!ChangeServiceConfig2W(service, SERVICE_CONFIG_DESCRIPTION, descriptionBuffer))
                {
                    int error = Marshal.GetLastWin32Error(); throw new Win32Exception(error, "ChangeServiceConfig2W(SERVICE_CONFIG_DESCRIPTION) failed after service creation; leave the disabled service for intent-based repair.");
                }
            }
        }
        finally
        {
            if (descriptionBuffer != IntPtr.Zero) Marshal.FreeHGlobal(descriptionBuffer);
            if (descriptionText != IntPtr.Zero) Marshal.FreeHGlobal(descriptionText);
            if (service != IntPtr.Zero) CloseServiceHandle(service);
            if (manager != IntPtr.Zero) CloseServiceHandle(manager);
            if (dependencyBuffer != IntPtr.Zero) Marshal.FreeHGlobal(dependencyBuffer);
        }
    }
}
'@
    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
}
function Invoke-WsmServiceIdentityCreateNative($Request) {
    if($script:WsmServiceIdentityNativeCallback -is [scriptblock]){return (& $script:WsmServiceIdentityNativeCallback $Request)}
    Initialize-WsmServiceIdentityNative
    [WsmServiceIdentityNative]::CreateDisabledManagedService([string]$Request.Name,[string]$Request.DisplayName,[string]$Request.BinaryPathName,[string]$Request.Account,[string[]]$Request.Dependencies,[string]$Request.Description)
    [pscustomobject]@{Created=$true;ServiceName=$Request.Name;StartType='Disabled';ServiceType='OwnProcess';NativeApi='CreateServiceW';ProductionVerified=$false}
}
function New-WsmManagedService($Desired,$Spec) {
    $policy=Get-WsmServiceAccountPolicy $Desired $Spec;if($policy.Mode -ne 'ManagedServiceAccount'){throw 'New-WsmManagedService accepts only explicitly reviewed managed service accounts.'}
    $credentialPlan=Get-WsmServiceAccountCredential $Desired $Spec @{};if(-not $credentialPlan.NativePasswordPointerIsNull -or $credentialPlan.Credential){throw 'Managed-service native creation must use a NULL native password pointer and no PSCredential.'}
    foreach($field in @('Name','DisplayName','BinaryPathName','Description','Dependencies')){if(-not $Desired.PSObject.Properties[$field]){throw ('Managed service requires typed desired field '+$field+'.')}}
    $name=[string]$Desired.Name;$display=[string]$Desired.DisplayName;$binary=[string]$Desired.BinaryPathName;$description=[string]$Desired.Description
    if([string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 256 -or $name -match '[/\\\x00-\x1f]' -or [string]::IsNullOrWhiteSpace($display) -or $display.Length -gt 256 -or $display -match '[\x00-\x1f]' -or [string]::IsNullOrWhiteSpace($binary) -or $binary.Length -gt 32767 -or $binary -match '[\x00-\x1f]' -or $description.Length -gt 32767 -or $description -match '[\x00-\x1f]'){throw 'Managed service name/display/binary/description is invalid or outside the supported bound.'}
    $dependencies=@($Desired.Dependencies);$multiSz=ConvertTo-WsmServiceDependencyMultiSz $dependencies;Initialize-WsmServiceIdentityNative;$nativeMultiSz=[WsmServiceIdentityNative]::BuildMultiSz([string[]]$dependencies)
    if($nativeMultiSz.Length -ne $multiSz.Characters.Length){throw 'Managed service native MULTI_SZ encoding length mismatch.'};for($i=0;$i -lt $nativeMultiSz.Length;$i++){if($nativeMultiSz[$i] -cne $multiSz.Characters[$i]){throw 'Managed service native MULTI_SZ encoding mismatch.'}}
    $request=[pscustomobject][ordered]@{Name=$name;DisplayName=$display;BinaryPathName=$binary;Account=$policy.CanonicalAccount;ServiceType='OwnProcess';ServiceTypeValue=[uint32]16;StartType='Disabled';StartTypeValue=[uint32]4;ErrorControlValue=[uint32]1;Dependencies=$dependencies;DependenciesMultiSz=$nativeMultiSz;Description=$description;PasswordPointer=[IntPtr]::Zero;PasswordMustBeNull=$true;Preflight=$credentialPlan.Policy;ProductionVerified=$false}
    $created=Invoke-WsmServiceIdentityCreateNative $request
    if($null -eq $created -or ($created -is [bool] -and -not $created) -or ($created -and $created.PSObject.Properties['Created'] -and -not [bool]$created.Created)){throw 'Native managed service creation callback returned failure.'}
    if($created -is [IntPtr] -and $created -eq [IntPtr]::Zero){throw 'Native managed service creation returned a null handle.'}
    if($created -isnot [bool] -and $created -isnot [IntPtr] -and -not $created.PSObject.Properties['Created']){throw 'Native managed service creation callback returned no typed success evidence.'}
    [pscustomobject]@{Created=$true;Request=$request;NativeResult=$created;ProductionVerified=$false}
}
