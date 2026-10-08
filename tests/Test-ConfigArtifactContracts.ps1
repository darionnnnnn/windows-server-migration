#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$contractPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\ConfigArtifactContracts.ps1'))
& $module {
    param($ContractPath)
    . $ContractPath
    function Assert-Config([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
    function Get-TestHash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
    function New-ConfigRow([string]$ItemId,[string]$Path,[string]$Hash,[long]$Attributes=32){
        [pscustomobject][ordered]@{ItemId=$ItemId;RelativePath=$Path;Directory=$false;Metadata=[pscustomobject]@{Sddl='O:SYG:SYD:(A;;FA;;;SY)';MetadataMode='DaclOwner';Attributes=$Attributes;CreationUtc='2026-10-08T00:00:00.0000000Z';LastWriteUtc='2026-10-08T00:00:00.0000000Z'};Data=[pscustomobject]@{Bytes=0;Hash=$Hash;Chunks=@()}}
    }
    function Write-ConfigIndex([string]$Path,[object[]]$Rows){$writer=New-Object IO.StreamWriter($Path,$false,(New-Object Text.UTF8Encoding($false)));try{foreach($row in $Rows){$writer.WriteLine((ConvertTo-Json -InputObject $row -Depth 20 -Compress))}}finally{$writer.Dispose()};Get-TestHash $Path}
    function New-TestManifest([string]$PlanHash,[string]$ArtifactsHash,[long]$Generation,[string]$BaseHash,[bool]$Final,$Plan){[pscustomobject]@{PlanHash=$PlanHash;ArtifactsHash=$ArtifactsHash;Generation=$Generation;BaseManifestHash=$BaseHash;Final=$Final;PairId=$Plan.PairId;BatchId=$Plan.BatchId;ApprovalId=$Plan.ApprovalId;Source=$Plan.Source;Target=$Plan.Target}}
    function Invoke-ConfigCompare($baseRows,$currentRows,$Plan,$PlanHash,$Root,[long]$CurrentGeneration=2,[string]$CurrentBaseHash,$ComparePlan=$Plan){
        $basePath=Join-Path $Root 'base.jsonl';$currentPath=Join-Path $Root 'current.jsonl';$baseIndexHash=Write-ConfigIndex $basePath $baseRows;$currentIndexHash=Write-ConfigIndex $currentPath $currentRows
        $baseManifest=New-TestManifest $PlanHash $baseIndexHash 1 '' $false $Plan;$baseManifestHash=Get-WsmHashText ('base-manifest-'+$baseIndexHash)
        if(-not $CurrentBaseHash){$CurrentBaseHash=$baseManifestHash};$currentManifest=New-TestManifest $PlanHash $currentIndexHash $CurrentGeneration $CurrentBaseHash $true $Plan;$currentManifestHash=Get-WsmHashText ('current-manifest-'+$currentIndexHash)
        Compare-WsmConfigArtifactIndexes -BaseArtifactsPath $basePath -BaseArtifactsHash $baseIndexHash -CurrentArtifactsPath $currentPath -CurrentArtifactsHash $currentIndexHash -Plan $ComparePlan -BasePlanHash $PlanHash -CurrentPlanHash $PlanHash -BaseManifest $baseManifest -BaseManifestHash $baseManifestHash -CurrentManifest $currentManifest -CurrentManifestHash $currentManifestHash
    }
    $testId=[Guid]::NewGuid().ToString('N');$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-test-config-'+$testId);[void][IO.Directory]::CreateDirectory($root)
    $draftWorkspace=Join-Path ([IO.Path]::GetTempPath()) ('wsm-test-config-output-'+$testId);[void][IO.Directory]::CreateDirectory($draftWorkspace)
    try {
        $itemId='1'*64;$source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint='a'*64};$target=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint='b'*64}
        $sourceScope=Join-Path $root 'scope';[void][IO.Directory]::CreateDirectory($sourceScope)
        $namedDirectory=Join-Path $sourceScope 'web.config';[void][IO.Directory]::CreateDirectory($namedDirectory);[IO.File]::WriteAllText((Join-Path $namedDirectory 'payload.dat'),'ordinary data')
        $nested=Join-Path $sourceScope 'nested';[void][IO.Directory]::CreateDirectory($nested);[IO.File]::WriteAllText((Join-Path $nested 'worker.exe.config'),'worker config')
        $excluded=Join-Path $sourceScope 'excluded';[void][IO.Directory]::CreateDirectory($excluded);[IO.File]::WriteAllText((Join-Path $excluded 'appsettings.json'),'excluded config')
        $scopeSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=$sourceScope;ExcludedRelativePaths=@('excluded')}
        $scopeSpecPath=Join-Path $root 'scope-spec.json';Write-WsmJson $scopeSpecPath $scopeSpec;$scopeSpecHash=Get-TestHash $scopeSpecPath
        $scopeDraftPath=Join-Path $draftWorkspace 'scope-draft.jsonl'
        $scopeDraft=Export-WsmConfigArtifactScopeDraft -SpecPath $scopeSpecPath -ExpectedHash $scopeSpecHash -ItemId $itemId -Path $scopeDraftPath
        $scopeDraftRows=@(Get-Content -LiteralPath $scopeDraftPath | ForEach-Object {ConvertFrom-WsmJson $_})
        Assert-Config ($scopeDraft.ReviewStatus -eq 'Draft' -and $scopeDraft.RequiresOwnerEvidenceReview -and $scopeDraftRows.Count -eq 1 -and @($scopeDraftRows | Where-Object RelativePath -EQ 'nested\worker.exe.config').Count -eq 1) 'Source scope draft did not ignore excluded/directory-name decoys or find known configuration files.'
        Assert-Config (($scopeDraftRows[0].PSObject.Properties.Name -join ',') -ceq 'RelativePath,SHA256,Owner,Evidence') 'Draft rows do not match ConfigFiles approval schema.'
        $blocked=$false;try{Export-WsmConfigArtifactScopeDraft -SpecPath $scopeSpecPath -ExpectedHash $scopeSpecHash -ItemId $itemId -Path (Join-Path $sourceScope 'nested\inside-draft.jsonl')|Out-Null}catch{$blocked=$_.Exception.Message -match 'overlaps'}
        Assert-Config $blocked 'Source scope draft allowed output inside the business scope.'
        $rootConfig=Join-Path $root 'app.config';[IO.File]::WriteAllText($rootConfig,'root app config')
        $rootSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=$rootConfig;ExcludedRelativePaths=@()};$rootSpecPath=Join-Path $root 'root-spec.json';Write-WsmJson $rootSpecPath $rootSpec
        $rootDraftPath=Join-Path $draftWorkspace 'root-draft.jsonl';$rootDraft=Export-WsmConfigArtifactScopeDraft -SpecPath $rootSpecPath -ExpectedHash (Get-TestHash $rootSpecPath) -ItemId $itemId -Path $rootDraftPath
        $rootDraftRow=ConvertFrom-WsmJson (Get-Content -LiteralPath $rootDraftPath -Raw).Trim()
        Assert-Config ($rootDraft.ConfigCount -eq 1 -and $rootDraftRow.RelativePath -ceq '') 'FileScope whose root is a known config file did not retain RelativePath empty.'
        $spec=[pscustomobject][ordered]@{Adapter='FileScope';SourcePath=(Join-Path $root 'site');ConfigFiles=@();ConfigOverrides=@()}
        $plan=[pscustomobject]@{BatchId=[Guid]::NewGuid().ToString();PairId=[Guid]::NewGuid().ToString();ApprovalId=[Guid]::NewGuid().ToString();Source=$source;Target=$target;Items=@([pscustomobject]@{ItemId=$itemId;Decision='Include';MigrationSpec=$spec})}
        $planHash='c'*64;$h1=Get-WsmHashText 'web-v1';$h2=Get-WsmHashText 'web-v2';$ha=Get-WsmHashText 'appsettings';$hd=Get-WsmHashText 'app-config';$hm=Get-WsmHashText 'metadata-only'
        $spec.ConfigFiles=@([pscustomobject]@{RelativePath='site\web.config';SHA256=$h1;Owner='Web owner';Evidence='Approved change CHG-1'},[pscustomobject]@{RelativePath='site\appsettings.json';SHA256=$ha;Owner='Web owner';Evidence='Approved change CHG-1'},[pscustomobject]@{RelativePath='site\metadata.exe.config';SHA256=$hm;Owner='Batch owner';Evidence='Approved change CHG-2'},[pscustomobject]@{RelativePath='site\old.exe.config';SHA256=(Get-WsmHashText 'old-config');Owner='Batch owner';Evidence='Approved change CHG-2'})
        Assert-WsmConfigArtifactSpec $spec
        $baseRows=New-Object 'System.Collections.Generic.List[object]';$currentRows=New-Object 'System.Collections.Generic.List[object]';$draftSourceRows=New-Object 'System.Collections.Generic.List[object]'
        # Force the producer/comparator through the existing 5,000-row sort-run boundary.
        for($n=0;$n -lt 5004;$n++){$name=('data\record-{0:D5}.dat' -f $n);$hash=Get-WsmHashText $name;$draftSourceRows.Add((New-ConfigRow $itemId $name $hash))}
        $baseRows.Add((New-ConfigRow $itemId 'site\web.config' $h1.ToUpperInvariant()));$baseRows.Add((New-ConfigRow $itemId 'site\appsettings.json' $ha));$baseRows.Add((New-ConfigRow $itemId 'site\metadata.exe.config' $hm 33));$baseRows.Add((New-ConfigRow $itemId 'site\old.exe.config' (Get-WsmHashText 'old-config')))
        foreach($row in $baseRows){$draftSourceRows.Add($row)}
        $currentRows.Add((New-ConfigRow $itemId 'site\web.config' $h2));$currentRows.Add((New-ConfigRow $itemId 'site\app.config' $hd));$currentRows.Add((New-ConfigRow $itemId 'site\metadata.exe.config' $hm 32))
        $draftPath=Join-Path $root 'draft-source.jsonl';$draftIndexHash=Write-ConfigIndex $draftPath $draftSourceRows.ToArray()
        $draft=@(Get-WsmConfigArtifactDraft -ArtifactsPath $draftPath -ExpectedHash $draftIndexHash -ItemId $itemId)
        Assert-Config ($draft.Count -eq 4 -and @($draft | Where-Object RelativePath -CEQ 'site\web.config').Count -eq 1) 'Draft producer missed known configuration paths.'
        $spec.ConfigFiles=@($draft | ForEach-Object {[pscustomobject]@{RelativePath=$_.RelativePath;SHA256=$_.SHA256;Owner='Reviewed owner';Evidence='Review record'}})
        $basePath=Join-Path $root 'base-approved.jsonl';$baseIndexHash=Write-ConfigIndex $basePath $baseRows.ToArray()
        $approval=Assert-WsmApprovedConfigArtifacts -Spec $spec -ArtifactsPath $basePath -ExpectedHash $baseIndexHash -ItemId $itemId
        Assert-Config ($approval.Valid -and $approval.ConfigCount -eq 4) 'Approved baseline did not validate against source export.'
        $legacySpec=[pscustomobject]@{Adapter='FileScope';SourcePath=(Join-Path $root 'site')}
        Assert-WsmConfigArtifactSpec $legacySpec
        Assert-Config (@(Get-WsmConfigSpecEntries $legacySpec 'ConfigFiles').Count -eq 0 -and @(Get-WsmConfigSpecEntries $legacySpec 'ConfigOverrides').Count -eq 0) 'Legacy FileScope without optional configuration fields failed under StrictMode.'
        $customPath='site\custom.settings';$customHash=Get-WsmHashText 'custom bytes'
        $overrideSpec=[pscustomobject]@{ConfigFiles=@([pscustomobject]@{RelativePath=$customPath;SHA256=$customHash;Owner='owner';Evidence='change'});ConfigOverrides=@([pscustomobject]@{RelativePath=$customPath;Classification='Configuration';Owner='owner';Evidence='change';Reason='Nonstandard application configuration'})}
        Assert-WsmConfigArtifactSpec $overrideSpec
        $badBusinessOverride=[pscustomobject]@{ConfigFiles=@([pscustomobject]@{RelativePath=$customPath;SHA256=$customHash;Owner='owner';Evidence='change'});ConfigOverrides=@([pscustomobject]@{RelativePath=$customPath;Classification='BusinessData';Owner='owner';Evidence='change';Reason='attempt'})}
        $blocked=$false;try{Assert-WsmConfigArtifactSpec $badBusinessOverride}catch{$blocked=$_.Exception.Message -match 'cannot bypass'}
        Assert-Config $blocked 'BusinessData override bypassed a fixed approved configuration hash.'
        $driftRows=@($baseRows.ToArray() | ForEach-Object {if($_.RelativePath -ceq 'site\web.config'){New-ConfigRow $itemId $_.RelativePath $h2}else{$_}})
        $driftPath=Join-Path $root 'drift.jsonl';$driftHash=Write-ConfigIndex $driftPath $driftRows
        $blocked=$false;try{Assert-WsmApprovedConfigArtifacts -Spec $spec -ArtifactsPath $driftPath -ExpectedHash $driftHash -ItemId $itemId|Out-Null}catch{$blocked=$_.Exception.Message -match 'drifted'}
        Assert-Config $blocked 'Source export accepted configuration bytes that drifted after plan approval.'
        [IO.File]::AppendAllText($basePath,"`n",(New-Object Text.UTF8Encoding($false)))
        $blocked=$false;try{Assert-WsmApprovedConfigArtifacts -Spec $spec -ArtifactsPath $basePath -ExpectedHash $baseIndexHash -ItemId $itemId|Out-Null}catch{$blocked=$_.Exception.Message -match 'hash'}
        Assert-Config $blocked 'Configuration helper accepted JSONL changed after the caller pinned its hash.'
        $result=Invoke-ConfigCompare $baseRows.ToArray() $currentRows.ToArray() $plan $planHash $root
        Assert-Config ($result.Valid -and $result.RequiresReapproval -and $result.Changes.Count -eq 4) 'Configuration add/modify/delete or rename changes did not require reapproval.'
        Assert-Config (@($result.Changes | Where-Object Change -EQ 'Modified').Count -eq 1 -and @($result.Changes | Where-Object Change -EQ 'Added').Count -eq 1 -and @($result.Changes | Where-Object Change -EQ 'Deleted').Count -eq 2) 'Configuration change classes were not identified exactly.'
        $same=Invoke-ConfigCompare $baseRows.ToArray() $baseRows.ToArray() $plan $planHash $root
        Assert-Config (-not $same.RequiresReapproval) 'Metadata-only changes incorrectly triggered configuration review.'
        $wrongPlan=ConvertFrom-WsmJson ($plan | ConvertTo-Json -Depth 20 -Compress);$wrongPlan.PairId=[Guid]::NewGuid().ToString()
        $blocked=$false;try{[void](Invoke-ConfigCompare $baseRows.ToArray() $currentRows.ToArray() $plan $planHash $root 2 '' $wrongPlan)}catch{$blocked=$_.Exception.Message -match 'does not bind'}
        Assert-Config $blocked 'Another plan identity was accepted as the configuration generation.'
        $blocked=$false;try{[void](Invoke-ConfigCompare $baseRows.ToArray() $currentRows.ToArray() $plan $planHash $root 3)}catch{$blocked=$_.Exception.Message -match 'generation'}
        Assert-Config $blocked 'Non-consecutive configuration generation was accepted.'
        $badSpec=[pscustomobject]@{ConfigOverrides=@([pscustomobject]@{RelativePath='site\*.json';Classification='BusinessData';Owner='owner';Evidence='proof';Reason='broad'})}
        $blocked=$false;try{Assert-WsmConfigArtifactSpec $badSpec}catch{$blocked=$_.Exception.Message -match 'wildcards|Unsafe'}
        Assert-Config $blocked 'Wildcard override was accepted.'
        $badSpec=[pscustomobject]@{ConfigOverrides=@([pscustomobject]@{RelativePath='site\secret.json';Classification='BusinessData';Owner='';Evidence='proof';Reason='reason'})}
        $blocked=$false;try{Assert-WsmConfigArtifactSpec $badSpec}catch{$blocked=$_.Exception.Message -match 'Owner'}
        Assert-Config $blocked 'Unowned configuration override was accepted.'
        $badSpec=[pscustomobject]@{ConfigOverrides=@([pscustomobject]@{RelativePath='site\web.config';Classification='BusinessData';Owner='owner';Evidence='proof';Reason='reviewed'})}
        Assert-WsmConfigArtifactSpec $badSpec
        Write-Host 'PASS: exact approved configuration byte baselines, known path drafts, reapproval for content/add/delete/rename, metadata-only tolerance, 5,004-row stream, plan/generation binding, and override negatives.'
    } finally {if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force};if([IO.Directory]::Exists($draftWorkspace)){Remove-Item -LiteralPath $draftWorkspace -Recurse -Force}}
} $contractPath
