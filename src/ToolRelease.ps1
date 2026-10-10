function Get-WsmToolFingerprint {
    $files=@(Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object Extension -In @('.ps1','.psm1','.psd1') | Sort-Object Name);$files+=@(Get-Item (Join-Path ([IO.Path]::GetDirectoryName($PSScriptRoot)) 'Start-ServerMigration.ps1'));$rows=@(foreach($f in $files){$f.Name+'|'+(Get-FileHash -LiteralPath $f.FullName).Hash.ToLowerInvariant()});Get-WsmHashText ($rows -join "`n")
}
function Initialize-WsmCrypt32OfflineChainVerifier {
    $loadedVerifier='WsmCrypt32OfflineChainVerifier' -as [type]
    if($loadedVerifier){$flags=$loadedVerifier.GetField('RequiredFlags');if(-not $flags -or [long]$flags.GetValue($null) -ne 3221233924L -or -not $loadedVerifier.GetMethod('ValidateCertificatePolicy')){throw 'An older Crypt32 verifier is already loaded; restart PowerShell before using this tool release.'};return}
    if ($env:OS -ne 'Windows_NT') { throw 'Crypt32 offline chain verification is available only on Windows.' }
    $source=@'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

public static class WsmCrypt32OfflineChainVerifier {
    public const uint CacheOnlyUrlRetrieval = 0x00000004;
    public const uint DisableAia = 0x00002000;
    public const uint DisableAuthRootAutoUpdate = 0x00000100;
    public const uint RevocationCheckChainExcludeRoot = 0x40000000;
    public const uint RevocationCheckCacheOnly = 0x80000000;
    public const uint RequiredFlags = CacheOnlyUrlRetrieval | DisableAia | DisableAuthRootAutoUpdate | RevocationCheckChainExcludeRoot | RevocationCheckCacheOnly;

    [StructLayout(LayoutKind.Sequential)] private struct TrustStatus { public uint ErrorStatus; public uint InfoStatus; }
    [StructLayout(LayoutKind.Sequential)] private struct Usage { public uint Count; public IntPtr Oids; }
    [StructLayout(LayoutKind.Sequential)] private struct UsageMatch { public uint Type; public Usage Usage; }
    [StructLayout(LayoutKind.Sequential)] private struct ChainPara {
        public uint Size; public UsageMatch RequestedUsage; public UsageMatch RequestedIssuancePolicy;
        public uint UrlRetrievalTimeout; public int CheckRevocationFreshnessTime; public uint RevocationFreshnessTime;
        public IntPtr CacheResync; public IntPtr StrongSignPara; public uint StrongSignFlags;
    }
    [StructLayout(LayoutKind.Sequential)] private struct ChainContext {
        public uint Size; public TrustStatus TrustStatus; public uint ChainCount; public IntPtr Chains;
        public uint LowerQualityCount; public IntPtr LowerQualityChains; public int HasFreshnessTime;
        public uint FreshnessTime; public uint CreateFlags; public Guid ChainId;
    }
    [StructLayout(LayoutKind.Sequential)] private struct SimpleChain {
        public uint Size; public TrustStatus TrustStatus; public uint ElementCount; public IntPtr Elements;
        public IntPtr TrustListInfo; public int HasFreshnessTime; public uint FreshnessTime;
    }
    [StructLayout(LayoutKind.Sequential)] private struct ChainElement {
        public uint Size; public IntPtr CertContext; public TrustStatus TrustStatus; public IntPtr RevocationInfo;
        public IntPtr IssuanceUsage; public IntPtr ApplicationUsage; public IntPtr ExtendedErrorInfo;
    }
    [StructLayout(LayoutKind.Sequential)] private struct CertContext {
        public uint EncodingType; public IntPtr Encoded; public uint EncodedLength; public IntPtr CertInfo; public IntPtr Store;
    }

    [DllImport("crypt32.dll", SetLastError=true)] private static extern IntPtr CertCreateCertificateContext(uint encodingType, byte[] encoded, uint encodedLength);
    [DllImport("crypt32.dll", SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CertGetCertificateChain(IntPtr engine, IntPtr certContext, IntPtr time, IntPtr additionalStore, ref ChainPara parameters, uint flags, IntPtr reserved, out IntPtr chainContext);
    [DllImport("crypt32.dll")] private static extern void CertFreeCertificateChain(IntPtr chainContext);
    [DllImport("crypt32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CertFreeCertificateContext(IntPtr certContext);

    private static void RequireNoErrors(uint errors, string scope) {
        if (errors != 0) throw new CryptographicException(scope + " trust error flags 0x" + errors.ToString("X8") + ".");
    }
    private static byte[] GetEncodedCertificate(IntPtr context) {
        CertContext cert = (CertContext)Marshal.PtrToStructure(context, typeof(CertContext));
        if (cert.Encoded == IntPtr.Zero || cert.EncodedLength == 0 || cert.EncodedLength > 1048576) throw new CryptographicException("Crypt32 returned malformed certificate bytes.");
        byte[] bytes = new byte[(int)cert.EncodedLength]; Marshal.Copy(cert.Encoded, bytes, 0, bytes.Length); return bytes;
    }
    public static void ValidateCertificatePolicy(byte[] der) {
        using (X509Certificate2 cert = (X509Certificate2)Activator.CreateInstance(typeof(X509Certificate2), new object[] { der })) {
            string oid = cert.SignatureAlgorithm.Value;
            if (oid != "1.2.840.113549.1.1.11" && oid != "1.2.840.113549.1.1.12" && oid != "1.2.840.113549.1.1.13" && oid != "1.2.840.10045.4.3.2" && oid != "1.2.840.10045.4.3.3" && oid != "1.2.840.10045.4.3.4")
                throw new CryptographicException("Certificate chain uses a weak or unsupported signature algorithm.");
            using (RSA rsa = RSACertificateExtensions.GetRSAPublicKey(cert)) {
                if (rsa != null) { if (rsa.KeySize < 2048) throw new CryptographicException("Certificate chain RSA key is below 2048 bits."); return; }
            }
            using (ECDsa ec = ECDsaCertificateExtensions.GetECDsaPublicKey(cert)) {
                if (ec == null || ec.KeySize < 256) throw new CryptographicException("Certificate chain has a weak or unsupported public key.");
            }
        }
    }
    public static string VerifyRootThumbprint(byte[] signerDer) {
        if (signerDer == null || signerDer.Length == 0 || signerDer.Length > 1048576) throw new CryptographicException("Signer certificate bytes are invalid.");
        IntPtr signerContext = CertCreateCertificateContext(0x00010001, signerDer, (uint)signerDer.Length);
        if (signerContext == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not create signer certificate context.");
        IntPtr chainContext = IntPtr.Zero;
        try {
            ChainPara parameters = new ChainPara(); parameters.Size = (uint)Marshal.SizeOf(typeof(ChainPara));
            if (!CertGetCertificateChain(IntPtr.Zero, signerContext, IntPtr.Zero, IntPtr.Zero, ref parameters, RequiredFlags, IntPtr.Zero, out chainContext))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Crypt32 could not build a cache-only certificate chain.");
            if (chainContext == IntPtr.Zero) throw new CryptographicException("Crypt32 returned an empty chain context.");
            ChainContext chain = (ChainContext)Marshal.PtrToStructure(chainContext, typeof(ChainContext));
            RequireNoErrors(chain.TrustStatus.ErrorStatus, "Combined chain");
            if (chain.ChainCount != 1 || chain.Chains == IntPtr.Zero) throw new CryptographicException("Crypt32 returned an ambiguous simple-chain array; exact enterprise root pinning requires one chain.");
            if (chain.LowerQualityCount != 0) throw new CryptographicException("Crypt32 returned lower-quality chain alternatives; verification fails closed.");
            IntPtr rootContext = IntPtr.Zero;
            for (uint chainIndex = 0; chainIndex < chain.ChainCount; chainIndex++) {
                IntPtr simplePtr = Marshal.ReadIntPtr(chain.Chains, checked((int)chainIndex * IntPtr.Size));
                if (simplePtr == IntPtr.Zero) throw new CryptographicException("Crypt32 returned a null simple chain.");
                SimpleChain simple = (SimpleChain)Marshal.PtrToStructure(simplePtr, typeof(SimpleChain));
                RequireNoErrors(simple.TrustStatus.ErrorStatus, "Simple chain");
                if (simple.ElementCount == 0 || simple.ElementCount > 128 || simple.Elements == IntPtr.Zero) throw new CryptographicException("Crypt32 returned an invalid chain-element array.");
                for (uint elementIndex = 0; elementIndex < simple.ElementCount; elementIndex++) {
                    IntPtr elementPtr = Marshal.ReadIntPtr(simple.Elements, checked((int)elementIndex * IntPtr.Size));
                    if (elementPtr == IntPtr.Zero) throw new CryptographicException("Crypt32 returned a null chain element.");
                    ChainElement element = (ChainElement)Marshal.PtrToStructure(elementPtr, typeof(ChainElement));
                    RequireNoErrors(element.TrustStatus.ErrorStatus, "Chain element");
                    if (element.CertContext == IntPtr.Zero) throw new CryptographicException("Crypt32 returned a chain element without a certificate.");
                    ValidateCertificatePolicy(GetEncodedCertificate(element.CertContext));
                    if (chainIndex == chain.ChainCount - 1 && elementIndex == simple.ElementCount - 1) rootContext = element.CertContext;
                }
            }
            if (rootContext == IntPtr.Zero) throw new CryptographicException("Crypt32 chain has no terminal root certificate.");
            byte[] rootDer = GetEncodedCertificate(rootContext); using (SHA1 sha = SHA1.Create()) { return BitConverter.ToString(sha.ComputeHash(rootDer)).Replace("-", "").ToUpperInvariant(); }
        } finally {
            if (chainContext != IntPtr.Zero) CertFreeCertificateChain(chainContext);
            CertFreeCertificateContext(signerContext);
        }
    }
}
'@
    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
}

function Get-WsmCrypt32OfflineChainRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    Initialize-WsmCrypt32OfflineChainVerifier
    [WsmCrypt32OfflineChainVerifier]::VerifyRootThumbprint($Certificate.RawData)
}

function Assert-WsmCmsAlgorithmPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DigestOid,[Parameter(Mandatory)][string]$SignatureOid,[Parameter(Mandatory)][ValidateSet('RSA','ECDSA')][string]$KeyAlgorithm,[Parameter(Mandatory)][int]$KeySize)
    if($DigestOid -cnotin @('2.16.840.1.101.3.4.2.1','2.16.840.1.101.3.4.2.2','2.16.840.1.101.3.4.2.3')){throw 'CMS digest must use SHA-256, SHA-384, or SHA-512.'}
    $rsaOids=@('1.2.840.113549.1.1.1','1.2.840.113549.1.1.11','1.2.840.113549.1.1.12','1.2.840.113549.1.1.13')
    $ecOids=@('1.2.840.10045.4.3.2','1.2.840.10045.4.3.3','1.2.840.10045.4.3.4')
    if($KeyAlgorithm -ceq 'RSA'){
        if($KeySize -lt 2048){throw 'RSA signer key must be at least 2048 bits.'};if($SignatureOid -cnotin $rsaOids){throw 'RSA signer certificate is paired with an unsupported CMS signature algorithm.'}
        $paired=@{'1.2.840.113549.1.1.11'='2.16.840.1.101.3.4.2.1';'1.2.840.113549.1.1.12'='2.16.840.1.101.3.4.2.2';'1.2.840.113549.1.1.13'='2.16.840.1.101.3.4.2.3'};if($paired.ContainsKey($SignatureOid) -and $paired[$SignatureOid] -cne $DigestOid){throw 'CMS digest and RSA signature algorithm do not match.'}
    } else {
        if($KeySize -lt 256){throw 'ECDSA signer key must be at least 256 bits.'};if($SignatureOid -cnotin $ecOids){throw 'ECDSA signer certificate is paired with an unsupported CMS signature algorithm.'}
        $paired=@{'1.2.840.10045.4.3.2'='2.16.840.1.101.3.4.2.1';'1.2.840.10045.4.3.3'='2.16.840.1.101.3.4.2.2';'1.2.840.10045.4.3.4'='2.16.840.1.101.3.4.2.3'};if($paired[$SignatureOid] -cne $DigestOid){throw 'CMS digest and ECDSA signature algorithm do not match.'}
    }
}

function Assert-WsmDetachedCmsSignature {
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$ContentBytes,[Parameter(Mandatory)][byte[]]$SignatureBytes,[Parameter(Mandatory)][string]$TrustPolicyPath,[Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$TrustPolicyHash,[Parameter(Mandatory)][ValidateSet('QualificationApprover','ReleaseSigner')][string]$Role)
    if($ContentBytes.Length -gt 64MB -or $SignatureBytes.Length -gt 4MB){throw 'Signed payload exceeds its verification limit.'}
    try {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
        $contentInfo=New-Object System.Security.Cryptography.Pkcs.ContentInfo -ArgumentList (,$ContentBytes)
        $cms=New-Object System.Security.Cryptography.Pkcs.SignedCms -ArgumentList $contentInfo,$true
        $cms.Decode($SignatureBytes);if($cms.SignerInfos.Count -ne 1){throw 'Exactly one independent enterprise signer is required.'};$cms.CheckSignature($true)
        $signer=$cms.SignerInfos[0].Certificate;if($null -eq $signer){throw 'Detached signature has no signer certificate.'}
        $digestOid=[string]$cms.SignerInfos[0].DigestAlgorithm.Value
        $keyUsage=@($signer.Extensions | Where-Object {$_.Oid.Value -eq '2.5.29.15'} | ForEach-Object {[Security.Cryptography.X509Certificates.X509KeyUsageExtension]$_})
        if($keyUsage.Count -ne 1 -or -not ($keyUsage[0].KeyUsages -band [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature)){throw 'Signer certificate must contain a digital-signature key-usage authorization.'}
        $keyStrength=''
        $signatureOid=[string]$cms.SignerInfos[0].SignatureAlgorithm.Value
        $rsa=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($signer);if($null -ne $rsa){try{Assert-WsmCmsAlgorithmPolicy -DigestOid $digestOid -SignatureOid $signatureOid -KeyAlgorithm RSA -KeySize $rsa.KeySize;$keyStrength='RSA-'+$rsa.KeySize}finally{$rsa.Dispose()}}
        else{$ecdsa=[Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPublicKey($signer);if($null -eq $ecdsa){throw 'Signer key must be RSA or ECDSA.'};try{Assert-WsmCmsAlgorithmPolicy -DigestOid $digestOid -SignatureOid $signatureOid -KeyAlgorithm ECDSA -KeySize $ecdsa.KeySize;$keyStrength='ECDSA-'+$ecdsa.KeySize}finally{$ecdsa.Dispose()}}
        $policy=Read-WsmTrustedJson $TrustPolicyPath $TrustPolicyHash;Assert-WsmEnvelope $policy EnterpriseTrustPolicy;Assert-WsmFields $policy @('SchemaVersion','ToolVersion','Kind','ExpiresUtc','Roles','RevokedThumbprints','RevocationEvidenceUpdatedUtc','RevocationMaxAgeHours','QualificationRevocations') @('ExpiresUtc','Roles','RevokedThumbprints','RevocationEvidenceUpdatedUtc','RevocationMaxAgeHours')
        if((ConvertTo-WsmQualificationUtc ([string]$policy.ExpiresUtc) TrustPolicyExpiresUtc) -le [DateTimeOffset]::UtcNow){throw 'Enterprise trust policy expired.'}
        $revocationUpdated=ConvertTo-WsmQualificationUtc ([string]$policy.RevocationEvidenceUpdatedUtc) RevocationEvidenceUpdatedUtc;if(($policy.RevocationMaxAgeHours -isnot [int] -and $policy.RevocationMaxAgeHours -isnot [long]) -or [int]$policy.RevocationMaxAgeHours -lt 1 -or [int]$policy.RevocationMaxAgeHours -gt 720 -or $revocationUpdated -gt [DateTimeOffset]::UtcNow.AddMinutes(5) -or $revocationUpdated.AddHours([int]$policy.RevocationMaxAgeHours) -le [DateTimeOffset]::UtcNow){throw 'Offline enterprise revocation evidence is missing, invalid, or stale.'}
        if(@($policy.Roles).Count -lt 1 -or @($policy.Roles).Count -gt 2 -or @($policy.Roles.Name | Select-Object -Unique).Count -ne @($policy.Roles).Count -or @($policy.Roles | Where-Object Name -CNotIn @('QualificationApprover','ReleaseSigner')).Count){throw 'Trust policy roles are invalid or duplicated.'};foreach($roleRow in $policy.Roles){Assert-WsmFields $roleRow @('Name','SignerThumbprints','RootThumbprints') @('Name','SignerThumbprints','RootThumbprints')}
        $rolePolicy=@($policy.Roles | Where-Object Name -CEQ $Role);if($rolePolicy.Count -ne 1){throw ('Trust policy does not define exactly one '+$Role+' role.')}
        Assert-WsmFields $rolePolicy[0] @('Name','SignerThumbprints','RootThumbprints') @('Name','SignerThumbprints','RootThumbprints')
        $allowed=@($rolePolicy[0].SignerThumbprints | ForEach-Object {([string]$_ -replace '\s','').ToUpperInvariant()});$allowedRoots=@($rolePolicy[0].RootThumbprints | ForEach-Object {([string]$_ -replace '\s','').ToUpperInvariant()});$revoked=@($policy.RevokedThumbprints | ForEach-Object {([string]$_ -replace '\s','').ToUpperInvariant()})
        if($allowed.Count -eq 0 -or $allowedRoots.Count -eq 0 -or @($allowed | Where-Object {$_ -notmatch '^[A-F0-9]{40,64}$'}).Count -or @($allowedRoots | Where-Object {$_ -notmatch '^[A-F0-9]{40,64}$'}).Count -or @($revoked | Where-Object {$_ -notmatch '^[A-F0-9]{40,64}$'}).Count){throw 'Trust policy has invalid or missing signer/root pins.'};if($signer.Thumbprint.ToUpperInvariant() -cnotin $allowed -or $signer.Thumbprint.ToUpperInvariant() -cin $revoked){throw 'Signer is not authorized or is revoked by enterprise policy.'}
        $chain=New-Object Security.Cryptography.X509Certificates.X509Chain
        try {
            $chain.ChainPolicy.RevocationMode=[Security.Cryptography.X509Certificates.X509RevocationMode]::Offline;$chain.ChainPolicy.RevocationFlag=[Security.Cryptography.X509Certificates.X509RevocationFlag]::ExcludeRoot;$chain.ChainPolicy.VerificationFlags=[Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag;$chain.ChainPolicy.UrlRetrievalTimeout=[TimeSpan]::Zero
            if($env:OS -eq 'Windows_NT'){$root=Get-WsmCrypt32OfflineChainRoot -Certificate $signer;$chainEngine='Crypt32CacheOnly'}
            else{throw 'Enterprise release chain verification is supported only on Windows with the cache-only Crypt32 provider.'}
            if($root -cnotin $allowedRoots -or $root -cin $revoked){throw 'Signer chain root is not authorized or is revoked by enterprise policy.'}
        } finally {$chain.Dispose()}
        [pscustomobject]@{Valid=$true;SignerThumbprint=$signer.Thumbprint.ToUpperInvariant();RootThumbprint=$root;Subject=$signer.Subject;Issuer=$signer.Issuer;VerifiedUtc=(Get-WsmUtc);TrustPolicyHash=$TrustPolicyHash.ToLowerInvariant();Role=$Role;DigestAlgorithmOid=$digestOid;SignerKeyStrength=$keyStrength;ChainEngine=$chainEngine;TrustBasis='Pinned enterprise signer/root and current offline certificate/CRL validation'}
    } catch {throw ('Independent enterprise signature verification failed: '+$_.Exception.Message)}
}

function Get-WsmReleaseArchiveProjection {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem;$archive=[IO.Compression.ZipFile]::OpenRead($Path)
    try {
        if($archive.Entries.Count -gt 10000){throw 'Release archive entry limit exceeded.'}
        $manifestEntries=@($archive.Entries | Where-Object FullName -CEQ 'release.json');if($manifestEntries.Count -ne 1){throw 'Release archive must have exactly one release.json manifest.'};$indexEntry=$manifestEntries[0];if($indexEntry.Length -gt 4MB){throw 'Release archive manifest exceeds its size limit.'}
        $reader=New-Object IO.StreamReader($indexEntry.Open(),[Text.Encoding]::UTF8,$true);try{$index=ConvertFrom-WsmJson $reader.ReadToEnd()}finally{$reader.Dispose()};Assert-WsmEnvelope $index ToolRelease
        if(@($index.Files).Count -gt 10000){throw 'Release manifest file limit exceeded.'};$expected=@{};$names=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($row in $index.Files){$entryPath=[string]$row.Path;if([string]::IsNullOrWhiteSpace($entryPath) -or $entryPath.Contains('\\') -or $entryPath.StartsWith('/') -or $entryPath -match '^[A-Za-z]:' -or @($entryPath.Split('/')) -contains '..' -or @($entryPath.Split('/')) -contains '.' -or $entryPath -match '[\x00-\x1f]'){throw 'Release manifest contains a nonportable or unsafe path.'};if($entryPath -ieq 'release.json' -or -not $names.Add($entryPath)){throw 'Release manifest contains a duplicate or reserved path.'};if([long]$row.Bytes -lt 0 -or [long]$row.Bytes -gt 1GB -or [string]$row.SHA256 -notmatch '^[a-f0-9]{64}$'){throw 'Release manifest has invalid file metadata.'};$expected[$entryPath]=$row}
        $actual=@($archive.Entries | Where-Object FullName -CNE 'release.json');if($actual.Count -ne $expected.Count){throw 'Release archive entry set differs from manifest.'};$actualNames=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase);$totalBytes=[long]0
        foreach($entry in $actual){if(-not $actualNames.Add($entry.FullName) -or -not $expected.ContainsKey($entry.FullName)){throw 'Release archive has duplicate or unmanifested files.'};$row=$expected[$entry.FullName];if($entry.Length -ne [long]$row.Bytes -or $entry.Length -gt 1GB){throw ('Release file size mismatch: '+$entry.FullName)};$totalBytes+=[long]$entry.Length;if($totalBytes -gt 1GB){throw 'Release expanded size exceeds 1 GiB.'};if($entry.CompressedLength -eq 0 -and $entry.Length -gt 0 -or $entry.CompressedLength -gt 0 -and ($entry.Length/[double]$entry.CompressedLength) -gt 200){throw 'Release file compression ratio exceeds limit.'};$stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create();try{$digest=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose();$stream.Dispose()};if($digest -cne [string]$row.SHA256){throw ('Release bytes differ from manifest: '+$entry.FullName)}}
        $toolRows=@($index.Files | Where-Object {$_.Path -match '^src/[^/]+\.(ps1|psm1|psd1)$'} | Sort-Object { [IO.Path]::GetFileName([string]$_.Path) });$entryPoint=@($index.Files | Where-Object Path -CEQ 'Start-ServerMigration.ps1');if($entryPoint.Count -ne 1){throw 'Release is missing or duplicates its entry point.'};$toolRows+=@($entryPoint[0]);$fp=Get-WsmHashText (@(foreach($row in $toolRows){[IO.Path]::GetFileName([string]$row.Path)+'|'+([string]$row.SHA256).ToLowerInvariant()}) -join "`n");if($fp -cne [string]$index.ToolFingerprint){throw 'Release tool fingerprint differs from final payload bytes.'}
        [pscustomobject]@{Index=$index;ToolFingerprint=$fp;FileCount=$actual.Count}
    } finally {$archive.Dispose()}
}

function Test-WsmToolRelease {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedHash,[Parameter(Mandatory)][string]$SignaturePath,[Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSignatureHash,[Parameter(Mandatory)][string]$TrustPolicyPath,[Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$TrustPolicyHash)
    if(-not [IO.File]::Exists($Path) -or (Get-Item -LiteralPath $Path).Length -gt 64MB -or (Get-FileHash -LiteralPath $Path).Hash -ine $ExpectedHash){throw 'Release bytes are missing, oversized, or differ from independently supplied expected hash.'};if(-not [IO.File]::Exists($SignaturePath) -or (Get-Item -LiteralPath $SignaturePath).Length -gt 4MB -or (Get-FileHash -LiteralPath $SignaturePath).Hash -ine $ExpectedSignatureHash){throw 'Signature bytes are missing, oversized, or differ from independently supplied expected hash.'}
    $projection=Get-WsmReleaseArchiveProjection $Path;$trust=Assert-WsmDetachedCmsSignature -ContentBytes ([IO.File]::ReadAllBytes([IO.Path]::GetFullPath($Path))) -SignatureBytes ([IO.File]::ReadAllBytes([IO.Path]::GetFullPath($SignaturePath))) -TrustPolicyPath $TrustPolicyPath -TrustPolicyHash $TrustPolicyHash -Role ReleaseSigner;
    [pscustomobject]@{Valid=$true;Path=[IO.Path]::GetFullPath($Path);SHA256=$ExpectedHash.ToLowerInvariant();ArchiveSHA256=$ExpectedHash.ToLowerInvariant();SignatureSHA256=$ExpectedSignatureHash.ToLowerInvariant();ToolFingerprint=$projection.ToolFingerprint;FileCount=$projection.FileCount;SignerThumbprint=$trust.SignerThumbprint;TrustPolicyHash=$TrustPolicyHash.ToLowerInvariant();TrustBasis=$trust.TrustBasis;ProductionVerified=$false;ExecutionEnabled=$false}
}

function Export-WsmToolRelease {
    param([string]$Path)
    $root=[IO.Path]::GetDirectoryName($PSScriptRoot);if([IO.File]::Exists($Path)){throw 'Release archive already exists.'};$files=@(Get-Item (Join-Path $root 'Start-ServerMigration.ps1'))+@(Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object Extension -In @('.ps1','.psm1','.psd1'))+@(Get-Item (Join-Path $root 'README.md'))+@(Get-ChildItem -LiteralPath (Join-Path $root 'docs') -Filter '*.md' -File -Recurse)+@(Get-Item (Join-Path $root 'docs/RELEASE-SBOM.json'))+@(Get-Item (Join-Path $root 'docs/SUPPORT-MATRIX.json'))
    $components=@([pscustomobject]@{Type='application';Name='Windows Server Migration';Version=$script:ToolVersion;Bundled=$true;Supplier='Project maintainers';License='NOASSERTION; repository has no declared license';PURL='pkg:generic/windows-server-migration@'+$script:ToolVersion},[pscustomobject]@{Type='platform';Name='Windows PowerShell';Version='5.1 x64';Bundled=$false;Supplier='Microsoft';License='Microsoft operating system component';PURL='pkg:generic/microsoft-windows-powershell@5.1'},[pscustomobject]@{Type='platform';Name='.NET Framework';Version='OS-provided';Bundled=$false;Supplier='Microsoft';License='Microsoft operating system component';PURL='pkg:generic/microsoft-dotnet-framework'});$index=[pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='ToolRelease';ToolFingerprint=(Get-WsmToolFingerprint);Files=@(foreach($file in $files){[pscustomobject]@{Path=$file.FullName.Substring($root.Length+1).Replace('\','/');Bytes=$file.Length;SHA256=(Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant();SignatureStatus=[string](Get-AuthenticodeSignature -LiteralPath $file.FullName).Status}});SBOMFormat='ProjectSBOM-1';Components=$components;Runtime='Windows PowerShell 5.1 x64 FullLanguage; adapter-required host roles/modules detected locally';ProductionVerified=$false;Deployment='Sign these final archive bytes under the enterprise ReleaseSigner role; independently verify archive hash, detached signature, pinned trust policy and exact byte release. Signing does not enable production.';CreatedUtc=(Get-WsmUtc)}
    Add-Type -AssemblyName System.IO.Compression.FileSystem;$temp=$Path+'.partial';$archive=$null
    try{$archive=[IO.Compression.ZipFile]::Open($temp,'Create');foreach($file in $files){[void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$file.FullName,$file.FullName.Substring($root.Length+1).Replace('\','/'))};$entry=$archive.CreateEntry('release.json');$writer=New-Object IO.StreamWriter($entry.Open(),(New-Object Text.UTF8Encoding($false)));try{$writer.Write(($index | ConvertTo-Json -Depth 10))}finally{$writer.Dispose()};$archive.Dispose();$archive=$null;[IO.File]::Move($temp,$Path)}finally{if($archive){$archive.Dispose()};if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
    [pscustomobject]@{Path=[IO.Path]::GetFullPath($Path);SHA256=(Get-FileHash -LiteralPath $Path).Hash;ToolFingerprint=$index.ToolFingerprint;ProductionVerified=$false;Signed=$false;NextStep='Sign these exact final archive bytes with the enterprise release certificate, then verify with Test-WsmToolRelease and an independently supplied trust policy hash.'}
}
