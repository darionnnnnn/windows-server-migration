# Module-scope test replacements for the offline restore journey (G). This file is
# dot-sourced inside the imported product module scope by G-JourneyHost.ps1; the
# product files in the snapshot stay untouched. ASCII only.

function Install-GIdentity {
    param([Parameter(Mandatory)][ValidateSet('Source','Manager')][string]$Role)
    $script:GIdentityRole=$Role
    function script:Get-WsmMachineIdentity {
        $fingerprint=if($script:GIdentityRole -ceq 'Source'){'a'*64}else{'c'*64}
        [pscustomobject]@{Fingerprint=$fingerprint;Name=('G-'+$script:GIdentityRole);OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}
    }
    function script:Get-WsmPreflight {
        [pscustomobject]@{OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true;PowerShellVersion='5.1';ExecutionPolicy='AllSigned';LanguageMode='FullLanguage'}
    }
}

function Install-GSourceInventory {
    param([Parameter(Mandatory)][string]$InventoryPath)
    $script:GSourceInventoryPath=$InventoryPath
    function script:Export-WsmInventory {
        param([string]$OutputDirectory,[switch]$DeepDiscovery,[switch]$IncludeSoftwareCatalog,[int]$MaxSoftwareEntries,[string[]]$PortableRoot,[string]$ManualEvidencePath,[string]$ManualEvidenceSha256)
        [pscustomobject]@{Path=$script:GSourceInventoryPath;SHA256=(Get-FileHash -LiteralPath $script:GSourceInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
}

function Install-GRemovableMedia {
    function script:Get-WsmIndependentCopyMediaClass {
        param($DestinationRoot)
        'Removable'
    }
}
