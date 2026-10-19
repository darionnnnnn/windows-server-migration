function Get-WsmFileScopeGuardReason {
    param([Parameter(Mandatory)][string]$Path)
    if($Path -match '^\\Device\\HarddiskVolume[^\\]+\\?'){
        $full=$Path.TrimEnd('\');$root=[regex]::Match($Path,'^\\Device\\HarddiskVolume[^\\]+').Value
    }else{
        $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
        $root=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path)).TrimEnd('\')
    }
    if($full -ieq $root){return 'drive root'}
    $normalized=$full.Replace('/','\')
    $volumeRoot=if($Path -match '^\\Device\\HarddiskVolume[^\\]+\\?'){[regex]::Match($Path,'^\\Device\\HarddiskVolume[^\\]+').Value}else{[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))}
    $parts=@($normalized.Substring($volumeRoot.Length).Trim('\') -split '\\' | Where-Object {$_})
    if($parts.Count -gt 0 -and $parts[0] -imatch '^(Windows(?:\.old)?|Program Files(?: \(x86\))?|ProgramW6432|WindowsApps|WinSxS|System Volume Information|\$Recycle\.Bin|Recovery|Boot|WindowsImageBackup)$'){
        return ('protected system/software directory: '+$parts[0])
    }
    if($parts.Count -gt 1 -and $parts[0] -ieq 'ProgramData' -and (($parts[1] -ieq 'Package Cache') -or ($parts[1] -ieq 'Microsoft' -and $parts.Count -gt 2 -and $parts[2] -ieq 'Windows'))){return 'protected Windows software state'}
    $leaf=[IO.Path]::GetFileName($full)
    if($leaf -imatch '^(pagefile|swapfile|hiberfil)\.sys$|^(bootmgr|bootnxt)$'){return 'operating system image or boot file'}
    return $null
}

function Test-WsmProtectedSoftwareInstallPath {
    param([Parameter(Mandatory)][string]$Path)
    if($Path -match '^\\Device\\HarddiskVolume[^\\]+\\?'){$canonical=$Path}else{$canonical=[IO.Path]::GetFullPath($Path)}
    $canonical=$canonical.Replace('/','\')
    $root=if($canonical -match '^\\Device\\HarddiskVolume[^\\]+\\?'){[regex]::Match($canonical,'^\\Device\\HarddiskVolume[^\\]+').Value}else{[IO.Path]::GetPathRoot($canonical)}
    $tail=$canonical.Substring($root.Length).Trim('\')
    $first=@($tail -split '\\' | Where-Object {$_} | Select-Object -First 1)
    return ($first.Count -gt 0 -and $first[0] -imatch '^(Program Files(?: \(x86\))?|ProgramW6432|WindowsApps)$')
}

function Test-WsmExactConfigPath {
    param([Parameter(Mandatory)][string]$RelativePath,[Parameter(Mandatory)][string]$SourceRoot)
    $leaf=if([string]::IsNullOrWhiteSpace($RelativePath)){[IO.Path]::GetFileName($SourceRoot.TrimEnd('\'))}else{[IO.Path]::GetFileName($RelativePath)}
    if($leaf -imatch '\.(exe|dll|sys|drv|ocx|com|msi|msp|cab|iso|wim|esd|vhd|vhdx|appx|msix)$'){return $false}
    return ($leaf -imatch '^(web\.config|app\.config|[^\\]+\.exe\.config|appsettings[^\\]*\.json|tnsnames\.ora|sqlnet\.ora|ldap\.ora|oraaccess\.xml)$' -or $leaf -imatch '^[^\\]+\.(config|json|xml|ini|ora|ya?ml|toml|conf|properties)$')
}

function Get-WsmTrustedInstalledSoftwareRoots {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$SourceInventory)
    if(-not $SourceInventory.PSObject.Properties['SoftwareCatalog']){
        return [pscustomobject]@{Status='Unavailable';Roots=@();Diagnostics=@('Source inventory has no captured SoftwareCatalog; installed-software roots were not independently covered.')}
    }
    if(-not (Get-Command Assert-WsmSoftwareCatalog -ErrorAction SilentlyContinue)){
        throw 'SoftwareCatalog validator is unavailable; installed-software scope cannot be verified.'
    }
    Assert-WsmSoftwareCatalog $SourceInventory.SoftwareCatalog -SourceInventory $SourceInventory | Out-Null
    $roots=New-Object 'System.Collections.Generic.List[object]';$seen=@{};$diagnostics=New-Object 'System.Collections.Generic.List[string]'
    $portableEntries=@($SourceInventory.SoftwareCatalog.Entries|Where-Object {$_.Scope -ceq 'Portable' -and $_.SourceKind -ceq 'PortableEvidence'})
    $requestedPortableRoots=New-Object 'System.Collections.Generic.List[string]'
    foreach($requested in @($SourceInventory.SoftwareCatalog.CaptureContext.RequestedPortableRoots)){
        try{$requestedRoot=ConvertTo-WsmCanonicalPath ([string]$requested);if([IO.Path]::GetPathRoot($requestedRoot) -match '^[A-Za-z]:\\$'){$requestedPortableRoots.Add($requestedRoot)}}catch{}
    }
    foreach($entry in @($SourceInventory.SoftwareCatalog.Entries)){
        $registryEligible=($entry.Scope -in @('Machine','User') -and $entry.SourceKind -ceq 'Registry' -and $entry.Evidence -and $entry.Evidence.PSObject.Properties['RegistryPath'] -and $entry.Evidence.PSObject.Properties['NaturalKey'])
        $portableEligible=($entry.Scope -ceq 'Portable' -and $entry.SourceKind -ceq 'PortableEvidence')
        if(-not ($registryEligible -or $portableEligible)){continue}
        $location=[string]$entry.Location
        if([string]::IsNullOrWhiteSpace($location) -or $location -match '^(?i:registry|inventory):' -or $location -match '%[^%]+%' -or -not [IO.Path]::IsPathRooted($location) -or $location.StartsWith('\\')){
            $diagnostics.Add(('Installed software evidence has no usable local root: '+[string]$entry.SoftwareId));continue
        }
        try{$canonical=ConvertTo-WsmCanonicalPath $location}catch{$diagnostics.Add(('Installed software evidence could not be canonicalized: '+[string]$entry.SoftwareId));continue}
        if($canonical -match '^\\\\\?\\|^\\Device\\' -or [IO.Path]::GetPathRoot($canonical) -notmatch '^[A-Za-z]:\\$'){$diagnostics.Add(('Installed software evidence is not a local drive path: '+[string]$entry.SoftwareId));continue}
        if($portableEligible){
            $matched=$false
            foreach($requestedRoot in $requestedPortableRoots){if($canonical.StartsWith($requestedRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){$key=$requestedRoot.TrimEnd('\').ToLowerInvariant();if(-not $seen.ContainsKey($key)){$seen[$key]=$true;$roots.Add([pscustomobject]@{Path=$requestedRoot;SoftwareId=[string]$entry.SoftwareId;SourceKind='PortableEvidence';Scope='Portable'})};$matched=$true}}
            if(-not $matched){$diagnostics.Add(('Portable software metadata has no matching requested portable root: '+[string]$entry.SoftwareId))}
            continue
        }
        $key=$canonical.TrimEnd('\').ToLowerInvariant()
        if(-not $seen.ContainsKey($key)){$seen[$key]=$true;$roots.Add([pscustomobject]@{Path=$canonical;SoftwareId=[string]$entry.SoftwareId;SourceKind=[string]$entry.SourceKind;Scope=[string]$entry.Scope})}
    }
    $coverage=@($SourceInventory.SoftwareCatalog.Coverage)
    $failedCoverage=@($coverage|Where-Object { [string]$_.Status -notin @('Success','NotInstalled') })
    if($failedCoverage.Count){$diagnostics.Add(('Software catalog coverage is partial: '+$failedCoverage.Count+' probe(s) did not complete successfully.'))}
    $registryCoverage=@($coverage|Where-Object { $_.Probe -eq 'Uninstall' -and $_.Scope -in @('Machine','User') })
    if(-not $registryCoverage.Count){$diagnostics.Add('No machine/user uninstall-registry coverage record is present in the software catalog.')}
    if(-not @($coverage).Count){$diagnostics.Add('Software catalog has no coverage records; installed-software completeness is unknown.')}
    $coveragePartial=($failedCoverage.Count -gt 0 -or $registryCoverage.Count -eq 0 -or $coverage.Count -eq 0 -or $diagnostics.Count -gt 0)
    return [pscustomobject]@{Status=$(if($coveragePartial){'Partial'}else{'Captured'});Roots=@($roots.ToArray());Diagnostics=@($diagnostics.ToArray())}
}

function Assert-WsmFileScopeInstalledRoots {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Spec,[Parameter(Mandatory)]$SourceInventory,[switch]$NativeSource)
    if($Spec.Adapter -cne 'FileScope' -or ($Spec.PSObject.Properties['ContentSelection'] -and [string]$Spec.ContentSelection -ceq 'ExactFiles')){
        return [pscustomobject]@{Status='NotApplicable';RootsChecked=0;Diagnostics=@()}
    }
    $inventoryRoots=Get-WsmTrustedInstalledSoftwareRoots $SourceInventory
    $sourceRoot=ConvertTo-WsmCanonicalPath ([string]$Spec.SourcePath)
    $sourceComparable=$sourceRoot;if($NativeSource){try{$sourceComparable=Get-WsmPhysicalPath $sourceRoot}catch{}}
    if($Spec.PSObject.Properties['ContentSelection'] -and [string]$Spec.ContentSelection -ceq 'ExactMembers'){
        foreach($member in @($Spec.Members)){
            $memberPath=ConvertTo-WsmCanonicalPath (Join-Path $sourceRoot ([string]$member.RelativePath));$memberComparable=$memberPath;if($NativeSource){$memberComparable=Get-WsmPhysicalPath $memberPath}
            foreach($install in @($inventoryRoots.Roots)){$installPath=[string]$install.Path;$installComparable=$installPath;if($NativeSource){$installComparable=Get-WsmPhysicalPath $installPath};if((Test-WsmPathOverlap $memberPath $installPath) -or (Test-WsmPathOverlap $memberComparable $installComparable)){throw ('ExactMembers includes a member covered by trusted installed-software evidence ('+[string]$install.SoftwareId+'): '+$memberPath+'. Review it as product configuration or exclude it from general data.')}}
        }
        return [pscustomobject]@{Status=$inventoryRoots.Status;RootsChecked=@($inventoryRoots.Roots).Count;Diagnostics=@($inventoryRoots.Diagnostics)}
    }
    $excluded=@(if($Spec.PSObject.Properties['ExcludedRelativePaths']){@($Spec.ExcludedRelativePaths)})
    $excludedPaths=New-Object 'System.Collections.Generic.List[object]'
    foreach($relative in $excluded){
        if([string]::IsNullOrWhiteSpace([string]$relative)){continue}
        Assert-WsmRelativePath ([string]$relative)
        $excludedPath=ConvertTo-WsmCanonicalPath (Join-Path $sourceRoot ([string]$relative));$excludedComparable=$excludedPath;if($NativeSource){try{$excludedComparable=Get-WsmPhysicalPath $excludedPath}catch{}};$excludedPaths.Add([pscustomobject]@{Logical=$excludedPath;Physical=$excludedComparable})
    }
    foreach($install in @($inventoryRoots.Roots)){
        $installPath=[string]$install.Path
        $installComparable=$installPath;if($NativeSource){try{$installComparable=Get-WsmPhysicalPath $installPath}catch{}}
        $insideSource=($installPath -ieq $sourceRoot -or $installPath.StartsWith($sourceRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or $installComparable -ieq $sourceComparable -or $installComparable.StartsWith($sourceComparable.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))
        $sourceInsideInstall=($sourceRoot -ieq $installPath -or $sourceRoot.StartsWith($installPath.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or $sourceComparable -ieq $installComparable -or $sourceComparable.StartsWith($installComparable.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))
        if(-not ($insideSource -or $sourceInsideInstall)){continue}
        $fullyExcluded=$false
        foreach($excludePath in $excludedPaths){if($installPath -ieq $excludePath.Logical -or $installPath.StartsWith($excludePath.Logical.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or $installComparable -ieq $excludePath.Physical -or $installComparable.StartsWith($excludePath.Physical.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){$fullyExcluded=$true;break}}
        if(-not $fullyExcluded){throw ('WholeScope intersects a trusted installed-software root ('+[string]$install.SoftwareId+'): '+$installPath+'. Add an explicit reviewed exclusion for that installed-software directory before sealing.')}
    }
    return [pscustomobject]@{Status=$inventoryRoots.Status;RootsChecked=@($inventoryRoots.Roots).Count;Diagnostics=@($inventoryRoots.Diagnostics)}
}

function Assert-WsmFileScopeContent {
    param([Parameter(Mandatory)][string]$Path,[switch]$ExactConfig)
    $extension=[IO.Path]::GetExtension($Path)
    if($extension -imatch '^\.(iso|wim|esd|vhd|vhdx)$'){
        throw ('OS/system image files are excluded from FileScope: '+$Path+'. Exclude this image explicitly and review any remaining business-data scope.')
    }
    $stream=[IO.File]::Open([IO.Path]::GetFullPath($Path),'Open','Read','Read')
    try{
        $head=New-Object byte[] 64;$read=$stream.Read($head,0,$head.Length)
        $pe=$false
        if($read -ge 64 -and $head[0] -eq 0x4d -and $head[1] -eq 0x5a){$offset=[BitConverter]::ToInt32($head,60);if($offset -ge 64 -and $offset -le 16777216 -and $stream.Length -ge ($offset+4)){[void]$stream.Seek($offset,[IO.SeekOrigin]::Begin);$signature=New-Object byte[] 4;if($stream.Read($signature,0,4) -eq 4 -and $signature[0] -eq 0x50 -and $signature[1] -eq 0x45 -and $signature[2] -eq 0 -and $signature[3] -eq 0){$pe=$true}}}
        $magic=if($read -ge 8){[Text.Encoding]::ASCII.GetString($head,0,8)}else{''}
        $elf=($read -ge 4 -and $head[0] -eq 0x7f -and [Text.Encoding]::ASCII.GetString($head,1,3) -ceq 'ELF')
        $machO=($read -ge 4 -and (([BitConverter]::ToString($head,0,4)) -in @('FE-ED-FA-CE','CE-FA-ED-FE','FE-ED-FA-CF','CF-FA-ED-FE','CA-FE-BA-BE','BE-BA-FE-CA')))
        $compound=($read -ge 8 -and [BitConverter]::ToString($head,0,8) -ceq 'D0-CF-11-E0-A1-B1-1A-E1')
        $cab=($read -ge 4 -and [Text.Encoding]::ASCII.GetString($head,0,4) -ceq 'MSCF')
        $archive=($read -ge 4 -and (([BitConverter]::ToString($head,0,4) -in @('50-4B-03-04','50-4B-05-06','50-4B-07-08')) -or ($read -ge 6 -and [BitConverter]::ToString($head,0,6) -ceq '37-7A-BC-AF-27-1C') -or ($read -ge 6 -and [BitConverter]::ToString($head,0,6) -ceq '52-61-72-21-1A-07') -or ($read -ge 2 -and [BitConverter]::ToString($head,0,2) -ceq '1F-8B')))
        $wim=($read -ge 8 -and $magic -ceq "MSWIM`0`0`0")
        $vhdx=($read -ge 8 -and $magic -ceq 'vhdxfile')
        $class=($read -ge 4 -and [BitConverter]::ToString($head,0,4) -ceq 'CA-FE-BA-BE')
        $vhd=$false;$iso=$false
        if($stream.Length -ge 512){[void]$stream.Seek(($stream.Length-512),[IO.SeekOrigin]::Begin);$footer=New-Object byte[] 8;if($stream.Read($footer,0,8) -eq 8 -and [Text.Encoding]::ASCII.GetString($footer,0,8) -ceq 'conectix'){$vhd=$true}}
        if($stream.Length -ge 32774){[void]$stream.Seek(32769,[IO.SeekOrigin]::Begin);$descriptor=New-Object byte[] 5;if($stream.Read($descriptor,0,5) -eq 5 -and [Text.Encoding]::ASCII.GetString($descriptor,0,5) -ceq 'CD001'){$iso=$true}}
        if($wim -or $vhdx -or $vhd -or $iso){throw ('OS/system image signature is excluded from FileScope: '+$Path+'. Exclude this image explicitly and review any remaining business-data scope.')}
        if($ExactConfig -and ($pe -or $elf -or $machO -or $compound -or $cab -or $class -or $archive)){throw ('Executable, installer, or archive content cannot qualify as exact configuration: '+$Path+'.')}
    }finally{$stream.Dispose()}
}

function Assert-WsmFileScopeGuard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Root','Collected','ExactConfig','ExactMembers')][string]$Mode='Collected',
        [string]$SourceRoot='',
        [string]$RelativePath='',
        [switch]$IsDirectory,
        [switch]$PathOnly,
        [switch]$MetadataOnly,
        [switch]$CheckPhysicalAlias,
        [switch]$AllowProtectedExactRoot,
        [switch]$AllowDriveRoot
    )
    $canonical=if($Path -match '^\\Device\\HarddiskVolume[^\\]+(?:\\|$)'){$Path.TrimEnd('\')}else{ConvertTo-WsmCanonicalPath $Path}
    $reason=Get-WsmFileScopeGuardReason $canonical
    if($reason){
        if($Mode -eq 'Root' -and $AllowDriveRoot -and $reason -eq 'drive root'){$reason=$null}
        elseif($Mode -eq 'Root' -and $AllowProtectedExactRoot -and $reason -ne 'drive root' -and (Test-WsmProtectedSoftwareInstallPath $canonical)){$reason=$null}
        elseif($Mode -eq 'ExactConfig' -and $IsDirectory -and (Test-WsmProtectedSoftwareInstallPath $canonical)){$reason=$null}
        elseif($Mode -eq 'ExactConfig' -and (Test-WsmExactConfigPath $(if($RelativePath){$RelativePath}else{$canonical}) $SourceRoot) -and (Test-WsmProtectedSoftwareInstallPath $canonical)){$reason=$null}
    }
    if($reason){throw ('FileScope reaches a protected OS/software path ('+$reason+'): '+$canonical+'. Review the business scope and explicitly exclude this path, or select only an owner-approved configuration file with ExactFiles.')}
    if($Mode -eq 'ExactConfig' -and -not $IsDirectory -and -not (Test-WsmExactConfigPath $(if($RelativePath){$RelativePath}else{$canonical}) $SourceRoot)){
        throw ('ExactFiles only accepts recognized configuration files; binary and arbitrary payload files are not configuration: '+$canonical)
    }
    if(-not $PathOnly -and -not $MetadataOnly -and -not $IsDirectory -and $Mode -in @('Collected','ExactConfig','ExactMembers') -and [IO.File]::Exists($canonical)){
        Assert-WsmNoReparse $canonical
        Assert-WsmFileScopeContent $canonical -ExactConfig:($Mode -eq 'ExactConfig')
    }
    if($CheckPhysicalAlias -and ([IO.File]::Exists($canonical) -or [IO.Directory]::Exists($canonical))){
        $physical=Get-WsmPhysicalPath $canonical
        $physicalReason=Get-WsmFileScopeGuardReason $physical
        $allowedPhysicalExact=($Mode -eq 'ExactConfig' -and (($IsDirectory -and (Test-WsmProtectedSoftwareInstallPath $physical)) -or ((Test-WsmExactConfigPath $(if($RelativePath){$RelativePath}else{$physical}) $SourceRoot) -and (Test-WsmProtectedSoftwareInstallPath $physical))))
        if($physicalReason -and -not (($Mode -eq 'Root' -and $AllowDriveRoot -and $physicalReason -eq 'drive root') -or ($Mode -eq 'Root' -and $AllowProtectedExactRoot -and $physicalReason -ne 'drive root' -and (Test-WsmProtectedSoftwareInstallPath $physical)) -or $allowedPhysicalExact)){
            throw ('FileScope resolves through a physical alias into a protected boundary ('+$physicalReason+'): '+$canonical)
        }
    }
}
