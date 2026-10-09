#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=New-Module -Name WsmOracleContractFixture -ScriptBlock {}
$oraclePath=(Join-Path $PSScriptRoot '..\src\OracleClientContracts.ps1')
$configPath=(Join-Path $PSScriptRoot '..\src\ConfigArtifactContracts.ps1')
$tempRoot=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('wsm-oracle-'+[Guid]::NewGuid().ToString('N'))))
[void][IO.Directory]::CreateDirectory($tempRoot)
try {
    & $module {
        param($oraclePath,$configPath,$tempRoot)
        Set-StrictMode -Version Latest
        . $configPath
        . $oraclePath
        $script:ToolVersion='fixture'

        function Assert-WsmFields($Object,[string[]]$Allowed,[string[]]$Required) {
            foreach($name in $Required){if(-not $Object.PSObject.Properties[$name]){throw ('Missing fixture field '+$name)}}
            foreach($property in $Object.PSObject.Properties){if($property.Name -notin $Allowed){throw ('Unexpected fixture field '+$property.Name)}}
        }
        function Get-WsmHashText([string]$Text) {$sha=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
        function Assert-WsmRelativePath([string]$Path,[switch]$AllowRoot) {if(-not $AllowRoot -and -not $Path){throw 'Empty relative path'};if($Path -match '(^|[\\/])\.\.([\\/]|$)' -or $Path -match '^[\\/]'){throw 'Unsafe relative path'}}
        function Assert-WsmNoReparse([string]$Path) {
            $full=[IO.Path]::GetFullPath($Path)
            if(-not ([IO.File]::Exists($full) -or [IO.Directory]::Exists($full))){throw ('Missing path '+$full)}
            $item=Get-Item -LiteralPath $full -Force
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Reparse point rejected'}
        }
        function Get-WsmPhysicalPath([string]$Path) { [IO.Path]::GetFullPath($Path) }
        function Test-WsmPathOverlap([string]$A,[string]$B) {
            $a=[IO.Path]::GetFullPath($A).TrimEnd('\')+'\';$b=[IO.Path]::GetFullPath($B).TrimEnd('\')+'\'
            return $a.StartsWith($b,[StringComparison]::OrdinalIgnoreCase) -or $b.StartsWith($a,[StringComparison]::OrdinalIgnoreCase)
        }
        function Read-WsmTrustedJson([string]$Path,[string]$ExpectedHash) {
            switch([IO.Path]::GetFileName($Path)) {
                'inventory.json' { return $script:FixtureInventory }
                'software-catalog.json' { return $script:FixtureCatalog }
                'spec.json' { return $script:FixtureSpec }
                'binding.json' { return $script:FixtureBinding }
                default { throw 'Unexpected fixture trusted input path.' }
            }
        }
        function Assert-WsmInventory($Inventory) { if($Inventory.Kind -cne 'Inventory'){throw 'Wrong inventory kind.'} }
        function Assert-WsmSoftwareCatalog($Catalog,$SourceInventory) { if($Catalog.Kind -cne 'SoftwareCatalog' -or $Catalog.Source.HostId -cne $SourceInventory.Source.HostId){throw 'Wrong software catalog binding.'};$true }
        function Assert-WsmMigrationSpec($Spec) { if($Spec.Adapter -cne 'FileScope'){throw 'Wrong FileScope kind.'} }
        function Assert-WsmEnvelope($Object,[string]$Kind) { if($Object.Kind -cne $Kind){throw 'Wrong fixture envelope.'} }
        function Write-WsmJson([string]$Path,$Object) { [IO.File]::WriteAllText($Path,($Object | ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($true))) }
        function Get-WsmGeneralHostRequirementId($Requirement) { Get-WsmHashText ($Requirement | ConvertTo-Json -Depth 20 -Compress) }
        function Get-WsmOracleNativeObservations($Inventory) {
            [pscustomobject]@{
                Candidates=@(
                    [pscustomobject]@{Source='MachineEnvironment';Name='TNS_ADMIN';Value='C:\candidate-machine';RegistryView='';CandidateOnly=$true;EffectiveValueProven=$false},
                    [pscustomobject]@{Source='LoadedUserEnvironment';Name='TNS_ADMIN';Value='C:\candidate-user';AccountSid='S-1-5-21-1-2-3-1001';RegistryView='';CandidateOnly=$true;EffectiveValueProven=$false},
                    [pscustomobject]@{Source='OracleRegistry';Name='TNS_ADMIN';Value='C:\candidate-32';RegistryView='Registry32';CandidateOnly=$true;EffectiveValueProven=$false},
                    [pscustomobject]@{Source='OracleRegistry';Name='TNS_ADMIN';Value='C:\candidate-64';RegistryView='Registry64';CandidateOnly=$true;EffectiveValueProven=$false}
                );Homes=@();Coverage=@();AdminProcessEnvironmentRead=$false
            }
        }

        $scope=Join-Path $tempRoot '來源 資料';$effective=Join-Path $scope 'tns 設定';$target=Join-Path $tempRoot '目標 資料';$outputRoot=Join-Path $tempRoot '交付';$appRoot=Join-Path $tempRoot '應用程式';$out=Join-Path $outputRoot 'draft.json'
        [void][IO.Directory]::CreateDirectory($effective);[void][IO.Directory]::CreateDirectory($target);[void][IO.Directory]::CreateDirectory($outputRoot);[void][IO.Directory]::CreateDirectory($appRoot)
        $tns=Join-Path $effective 'tnsnames.ora';$ifile=Join-Path $effective '附加 設定.ora';$wallet=Join-Path $effective 'cwallet.sso'
        $tnsText="# fixture Chinese path $([char]0x4e2d) Alias=(DESCRIPTION=(ADDRESS=(HOST=private.example)))`r`nIFILE=`"$ifile`"`r`n"
        [IO.File]::WriteAllText($tns,$tnsText,(New-Object Text.UnicodeEncoding($false,$true,$true)))
        [IO.File]::WriteAllText($ifile,'OWNER APPROVED INCLUDED FILE',(New-Object Text.UTF8Encoding($true)))
        [IO.File]::WriteAllText($wallet,'WALLET-PRIVATE-SENTINEL',(New-Object Text.UTF8Encoding($false)))
        $application=Join-Path $appRoot 'consumer.exe';$applicationConfig=$application+'.config';[IO.File]::WriteAllText($application,'fixture executable; never run',(New-Object Text.UTF8Encoding($false)));[IO.File]::WriteAllText($applicationConfig,"<configuration><appSettings><add key=`"TNS_ADMIN`" value=`"$effective`" /></appSettings></configuration>",(New-Object Text.UTF8Encoding($true)))
        $itemId='1'*64;$source=[pscustomobject]@{HostId='fixture-host';Fingerprint=('f'*64)}
        $script:FixtureInventory=[pscustomobject]@{Kind='Inventory';Source=$source;Items=@([pscustomobject]@{ItemId=$itemId;Kind='Service';Settings=[pscustomobject]@{PathName='"'+$application+'" --password=never-output'}})}
        $script:FixtureCatalog=[pscustomobject]@{Kind='SoftwareCatalog';Source=[pscustomobject]@{HostId=$source.HostId;Fingerprint=$source.Fingerprint};Entries=@([pscustomobject]@{SoftwareId=('sw-'+('a'*32));Name='Oracle ODP.NET Managed Client';Publisher='Oracle';Version='19.3.0';Architecture='Unknown';SourceKind='Registry';ItemIds=@()})}
        $script:FixtureSpec=[pscustomobject]@{Kind='MigrationSpec';Adapter='FileScope';SourcePath=$scope;TargetPath=$target;ExcludedRelativePaths=@('tns 設定\cwallet.sso');ConfigFiles=@();ConfigOverrides=@()}
        $consumer=[pscustomobject][ordered]@{ProviderSoftwareId=('sw-'+('a'*32));ProviderItemId='';Provider='ODP.NET.Managed';Version='19.3.0';Architecture='x64';OracleHome=(Join-Path $tempRoot 'oracle-home');AccountType='Service';AccountName='FixtureSvc';AccountSid='S-1-5-21-1-2-3-1001';ConsumerItemIds=@($itemId);ObservedEffectivePath=$effective;ApprovedIFiles=@($ifile);Owner='Fixture service owner';Evidence='Signed fixture attestation';ReviewStatus='OwnerConfirmed'}
        $consumer | Add-Member NoteProperty ConsumerId (Get-WsmOracleConsumerId $consumer)
        $script:FixtureBinding=[pscustomobject]@{SchemaVersion=1;Kind='OracleConsumerBinding';BindingVersion=1;ReviewStatus='OwnerConfirmed';ConnectionProofStatus='NotTested';ProductionVerified=$false;SourceHostId=$source.HostId;SourceFingerprint=$source.Fingerprint;InventoryHash=('a'*64);SoftwareCatalogHash=('d'*64);Consumers=@($consumer)}

        $candidateSet=Get-WsmOracleClientCandidates -Inventory $script:FixtureInventory -ConsumerBinding $script:FixtureBinding
        if($candidateSet.AdminProcessEnvironmentRead -ne $false -or @($candidateSet.Candidates | Where-Object Source -eq ProcessEnvironment).Count){throw 'Administrator process environment was used as Oracle effective-path evidence.'}
        if(@($candidateSet.Candidates | Where-Object RegistryView -eq Registry32).Count -ne 1 -or @($candidateSet.Candidates | Where-Object RegistryView -eq Registry64).Count -ne 1){throw 'Both Oracle registry views must remain distinct candidates.'}
        if(@($candidateSet.Candidates | Where-Object Source -eq ApplicationConfig | Where-Object Value -eq $effective | Where-Object EffectiveValueProven -eq $false).Count -ne 1){throw 'Application-level TNS_ADMIN must be surfaced as candidate-only evidence.'}
        if(@($candidateSet.Homes | Where-Object Source -eq OwnerBoundDefaultHomeFallbackCandidate | Where-Object Status -eq ProviderVersionSpecificBehaviorRequiresOwnerObservation | Where-Object EffectiveValueProven -eq $false).Count -ne 1){throw 'Default Home fallback must remain a provider-specific owner-observation candidate.'}
        $candidateEntries=New-Object 'System.Collections.Generic.List[object]';Add-WsmOracleEnvironmentCandidates $candidateEntries @{TNS_ADMIN='C:\candidate-machine';LOCAL='SECRET CONNECT DESCRIPTOR';PATH='C:\oracle\bin;C:\windows\system32'} 'MachineEnvironment'
        if(@($candidateEntries.ToArray() | Where-Object Name -eq 'LOCAL' | Where-Object Value -match 'SECRET').Count){throw 'LOCAL connect descriptor leaked into candidate output.'}
        if(@($candidateEntries.ToArray() | Where-Object Name -eq 'PATH' | Where-Object Action -eq ExternalManualMerge).Count -ne 1){throw 'PATH must remain a manual merge candidate.'}
        $oversizedCandidates=New-Object 'System.Collections.Generic.List[object]';Add-WsmOracleEnvironmentCandidates $oversizedCandidates @{TNS_ADMIN=('x'*8192)} 'MachineEnvironment';if(@($oversizedCandidates.ToArray() | Where-Object Oversize -eq $true | Where-Object Value -match '^\[value withheld').Count -ne 1){throw 'Oversized environment candidates must be bounded and withheld.'}

        $templateInput=[pscustomobject][ordered]@{ProviderSoftwareId=$consumer.ProviderSoftwareId;ProviderItemId='';Provider=$consumer.Provider;Version=$consumer.Version;Architecture=$consumer.Architecture;OracleHome=$consumer.OracleHome;AccountType=$consumer.AccountType;AccountName=$consumer.AccountName;AccountSid=$consumer.AccountSid;ConsumerItemIds=@($consumer.ConsumerItemIds);ObservedEffectivePath=$consumer.ObservedEffectivePath;ApprovedIFiles=@($consumer.ApprovedIFiles)}
        $templatePath=Join-Path $outputRoot 'owner-binding-template.json'
        $templateResult=Export-WsmOracleConsumerBindingTemplate -InventoryPath (Join-Path $tempRoot 'inventory.json') -ExpectedInventoryHash ('a'*64) -SoftwareCatalogPath (Join-Path $tempRoot 'software-catalog.json') -ExpectedSoftwareCatalogHash ('d'*64) -Consumers @($templateInput) -Path $templatePath
        $template=Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json
        if($templateResult.Trusted -or $template.ReviewStatus -cne 'OwnerReviewRequired' -or $template.SoftwareCatalogHash -cne ('d'*64) -or $template.Consumers[0].ReviewStatus -cne 'OwnerReviewRequired'){throw 'Consumer binding template did not remain an untrusted owner-review draft.'}

        $draftResult=Get-WsmOracleClientConfigDraft -InventoryPath (Join-Path $tempRoot 'inventory.json') -ExpectedInventoryHash ('a'*64) -SoftwareCatalogPath (Join-Path $tempRoot 'software-catalog.json') -ExpectedSoftwareCatalogHash ('d'*64) -FileScopeSpecPath (Join-Path $tempRoot 'spec.json') -ExpectedSpecHash ('c'*64) -ConsumerBindingPath (Join-Path $tempRoot 'binding.json') -ExpectedBindingHash ('b'*64) -Path $out
        $draft=Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
        if($draft.Status -cne 'OwnerAttestedStaticOnly' -or $draft.ConnectionProofStatus -cne 'NotTested' -or $draft.ProductionVerified){throw ('Unexpected Oracle proof state: '+$draft.Status+'/'+$draft.ConnectionProofStatus+'/'+$draft.ProductionVerified+' issues='+(@($draft.Issues | ForEach-Object {$_.Code+':'+$_.Reason}) -join ';'))}
        if(@($draft.ConfigFiles | Where-Object RelativePath -eq 'tns 設定\tnsnames.ora').Count -ne 1 -or @($draft.ConfigFiles | Where-Object RelativePath -eq 'tns 設定\附加 設定.ora').Count -ne 1){throw 'TNS or explicitly approved IFILE was not included in precise ConfigFiles.'}
        $mainConfig=@($draft.ConfigFiles | Where-Object RelativePath -eq 'tns 設定\tnsnames.ora')[0]
        if($mainConfig.OracleClient.Encoding -cne 'UTF-16LE' -or $mainConfig.SHA256 -cne (Get-WsmOracleFileEncodingAndReferences $tns).SHA256){throw 'Original encoding or exact raw-byte hash was not preserved.'}
        if(@($draft.ConfigFiles | Where-Object RelativePath -match 'cwallet').Count){throw 'Wallet material was included in ConfigFiles.'}
        if(@($draft.ExternalMaterials | Where-Object Class -eq ExternalSecretOrWallet | Where-Object IncludedInPackage -ne $false).Count -or @($draft.Issues | Where-Object Code -eq ExternalMaterialInsidePackageScope).Count){throw 'Wallet was not explicitly excluded from ordinary delivery.'}
        if($draft.CandidateObservations.AdminProcessEnvironmentRead -ne $false -or @($draft.Consumers | Where-Object NativeTnsAdminCandidateMatched -eq $true).Count -or @($draft.Consumers | Where-Object ApplicationTnsAdminCandidateMatched -ne $true).Count){throw 'Candidate evidence was not separated from the owner-bound effective path.'}
        if(@($draft.Requirements | Where-Object Type -eq Preparation | Where-Object RequiredPhase -eq StagedDependencyVerified).Count -ne 1 -or @($draft.Requirements | Where-Object { $_.Type -eq 'ExternalDependency' -and $_.RequiredPhase -eq 'CutoverReady' -and $_.SourceProof.EvidenceKind -eq 'ExternalOwner' }).Count -ne 1){throw 'Staged static and CutoverReady external owner proof relations are not distinct.'}
        if(@($draft.Requirements | Where-Object { $_.Type -eq 'ExternalDependency' -and $_.SourceProof.ProofStatus -ne 'NotTested' }).Count){throw 'Actual consumer proof must remain NotTested.'}
        Assert-WsmOracleConfigFileBinding $mainConfig
        $planItem=[pscustomobject]@{ItemId=$itemId;Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=$scope;ExcludedRelativePaths=@('tns 設定\cwallet.sso');ConfigFiles=@($draft.ConfigFiles);ConfigOverrides=@()}}
        $ownership=Assert-WsmOraclePlanConfigOwnership ([pscustomobject]@{Items=@($planItem)})
        if(-not $ownership.Valid -or $ownership.OracleConfigFiles -ne 2){throw 'Oracle ConfigFiles did not bind to a single FileScope owner.'}
        $duplicateItem=[pscustomobject]@{ItemId=('2'*64);Decision='Include';MigrationSpec=$planItem.MigrationSpec}
        $rejected=$false;try{Assert-WsmOraclePlanConfigOwnership ([pscustomobject]@{Items=@($planItem,$duplicateItem)}) | Out-Null}catch{$rejected=$true};if(-not $rejected){throw 'Shared Oracle config with multiple authoritative FileScope owners was accepted.'}
        $serialized=Get-Content -LiteralPath $out -Raw
        if($serialized -match 'private\.example|WALLET-PRIVATE-SENTINEL|Alias=|never-output|--password'){throw 'Oracle raw config content or consumer command argument leaked into draft JSON.'}

        $closure=Get-WsmOracleConfigFileClosure @($tns) $scope @('tns 設定\cwallet.sso') @($ifile)
        if(-not $closure.Valid -or @($closure.Files).Count -ne 2){throw 'Nested owner-approved IFILE closure should resolve safely.'}
        $cycle=Join-Path $effective 'cycle.ora';[IO.File]::WriteAllText($cycle,"IFILE=`"$cycle`"`r`n",(New-Object Text.UTF8Encoding($false)))
        $cycleResult=Get-WsmOracleConfigFileClosure @($cycle) $scope @() @($cycle)
        if($cycleResult.Valid -or @($cycleResult.Issues | Where-Object Code -eq IFILECycle).Count -ne 1){throw 'IFILE cycle was not blocked.'}
        $outside=Join-Path $tempRoot 'outside.ora';[IO.File]::WriteAllText($outside,'OUTSIDE',(New-Object Text.UTF8Encoding($false)))
        $outsideRef=Join-Path $effective 'outside-ref.ora';[IO.File]::WriteAllText($outsideRef,"IFILE=`"$outside`"`r`n",(New-Object Text.UTF8Encoding($false)))
        $outsideResult=Get-WsmOracleConfigFileClosure @($outsideRef) $scope @() @($outside)
        if($outsideResult.Valid -or @($outsideResult.Issues | Where-Object Code -eq UnsafeOrMissingReference).Count -lt 1){throw 'IFILE outside approved FileScope was not blocked.'}
        $missing=Join-Path $effective 'missing.ora';$missingRef=Join-Path $effective 'missing-ref.ora';[IO.File]::WriteAllText($missingRef,"IFILE=`"$missing`"`r`n",(New-Object Text.UTF8Encoding($false)))
        $missingResult=Get-WsmOracleConfigFileClosure @($missingRef) $scope @() @($missing)
        if($missingResult.Valid -or @($missingResult.Issues | Where-Object Code -eq UnsafeOrMissingReference).Count -lt 1){throw 'Missing IFILE was not blocked.'}
        $uncResult=Get-WsmOracleConfigFileClosure @('\\server\share\tnsnames.ora') $scope @() @()
        if($uncResult.Valid -or @($uncResult.Issues | Where-Object Code -eq UnsafeOrMissingReference).Count -ne 1){throw 'UNC configuration path was not blocked.'}

        $sqlnet=Join-Path $effective 'sqlnet.ora';[IO.File]::WriteAllText($sqlnet,"WALLET_LOCATION = (SOURCE = (METHOD = FILE) (METHOD_DATA = (DIRECTORY = `"$wallet`")))`r`n",(New-Object Text.UTF8Encoding($false)))
        $walletParse=Get-WsmOracleFileEncodingAndReferences $sqlnet
        if(@($walletParse.WalletReferenceHashes).Count -ne 1 -or ($walletParse | ConvertTo-Json -Compress) -match 'cwallet|WALLET-PRIVATE-SENTINEL') {throw 'Wallet config references must be retained as hashes without exposing path or content.'}
        $walletDraftPath=Join-Path $outputRoot 'wallet-reference-draft.json'
        Get-WsmOracleClientConfigDraft -InventoryPath (Join-Path $tempRoot 'inventory.json') -ExpectedInventoryHash ('a'*64) -SoftwareCatalogPath (Join-Path $tempRoot 'software-catalog.json') -ExpectedSoftwareCatalogHash ('d'*64) -FileScopeSpecPath (Join-Path $tempRoot 'spec.json') -ExpectedSpecHash ('c'*64) -ConsumerBindingPath (Join-Path $tempRoot 'binding.json') -ExpectedBindingHash ('b'*64) -Path $walletDraftPath | Out-Null
        $walletDraft=Get-Content -LiteralPath $walletDraftPath -Raw | ConvertFrom-Json
        if($walletDraft.Status -cne 'Blocked' -or @($walletDraft.Issues | Where-Object Code -eq ExternalWalletReferenceRequiresOwnerDelivery).Count -ne 1 -or @($walletDraft.ExternalMaterials | Where-Object { $_.ScopeRelation -eq 'Unknown' -and $_.Class -eq 'ExternalSecretOrWallet' -and $_.IncludedInPackage -eq $false -and $_.ReferenceHash -match '^[a-f0-9]{64}$' }).Count -ne 1){throw 'Wallet reference did not require external owner delivery and keep the consumer blocked.'}
        if((Get-Content -LiteralPath $walletDraftPath -Raw).Contains($wallet) -or (Get-Content -LiteralPath $walletDraftPath -Raw) -match 'WALLET-PRIVATE-SENTINEL'){throw 'Wallet reference path or material leaked into output.'}
        $unexcluded=[pscustomobject]@{RelativePath='tns 設定\cwallet.sso';IncludedInPackage=$false;Class='ExternalSecretOrWallet';Status='ExternalRequired';ReferenceHash='';ScopeRelation='InsideScope'}
        $rejected=$false;try{Assert-WsmOracleExternalMaterialExclusions ([pscustomobject]@{ExcludedRelativePaths=@()}) ([pscustomobject]@{ExternalMaterials=@($unexcluded)})}catch{$rejected=$true};if(-not $rejected){throw 'Wallet without exact FileScope exclusion was accepted.'}
        $badBinding=$consumer.PSObject.Copy();$badBinding.ProviderSoftwareId='software-invalid';$rejected=$false;try{Assert-WsmOracleConsumerShape $badBinding | Out-Null}catch{$rejected=$true};if(-not $rejected){throw 'Invalid provider software source binding was accepted.'}
        $versionMismatch=$consumer.PSObject.Copy();$versionMismatch.Version='18.1';$rejected=$false;try{Assert-WsmOracleProviderRows @($versionMismatch) $script:FixtureCatalog}catch{$rejected=$true};if(-not $rejected){throw 'Owner-bound provider version that differs from B1 was accepted.'}
        $architectureMismatch=$script:FixtureCatalog.PSObject.Copy();$architectureMismatch.Entries=@([pscustomobject]@{SoftwareId=$consumer.ProviderSoftwareId;Name='Oracle ODP.NET Managed Client';Publisher='Oracle';Version='19.3.0';Architecture='x64';SourceKind='Registry';ItemIds=@()});$wrongArchConsumer=$consumer.PSObject.Copy();$wrongArchConsumer.Architecture='x86';$rejected=$false;try{Assert-WsmOracleProviderRows @($wrongArchConsumer) $architectureMismatch}catch{$rejected=$true};if(-not $rejected){throw 'Owner-bound provider architecture that differs from independent catalog evidence was accepted.'}
        $badOwner=$consumer.PSObject.Copy();$badOwner.Owner='owner password=secret';$rejected=$false;try{Assert-WsmOracleConsumerShape $badOwner | Out-Null}catch{$rejected=$true};if(-not $rejected){throw 'Credential-like owner field was accepted.'}
        $wrongSource=$script:FixtureBinding.PSObject.Copy();$wrongSource.SourceFingerprint=('0'*64);$script:FixtureBinding=$wrongSource;$rejected=$false;try{Read-WsmOracleConsumerBinding (Join-Path $tempRoot 'binding.json') ('b'*64) $script:FixtureInventory ('a'*64) (Join-Path $tempRoot 'software-catalog.json') ('d'*64) | Out-Null}catch{$rejected=$true};if(-not $rejected){throw 'Binding for another source fingerprint was accepted.'}
        $wrongCatalog=$script:FixtureCatalog.PSObject.Copy();$wrongCatalog.Entries=@([pscustomobject]@{SoftwareId=('sw-'+('c'*32));Name='Oracle ODP.NET';Publisher='Oracle';Version='19.3.0';Architecture='Unknown';SourceKind='Registry';ItemIds=@()});$script:FixtureCatalog=$wrongCatalog;$rejected=$false;try{Assert-WsmOracleProviderRows @($consumer) $script:FixtureCatalog}catch{$rejected=$true};if(-not $rejected){throw 'Provider software ID absent from pinned B1 catalog was accepted.'}

        Write-Host 'PASS: B2 fixture preserves Oracle config bytes and scope, keeps candidate/effective identity separate, blocks unsafe IFILE/wallet cases, and separates staged readback from actual owner proof.'
    } $oraclePath $configPath $tempRoot
} finally {
    $resolved=[IO.Path]::GetFullPath($tempRoot);$tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'wsm-oracle-*'){throw 'Refusing to clean an unexpected test path.'}
    if([IO.Directory]::Exists($resolved)){[IO.Directory]::Delete($resolved,$true)}
}
