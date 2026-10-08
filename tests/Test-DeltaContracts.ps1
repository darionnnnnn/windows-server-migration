#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$deltaPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\DeltaContracts.ps1'))
& $module {
    param($DeltaPath)
    . $DeltaPath
    # Keep contract fixtures deterministic even when another agent edits release
    # files concurrently. The rejection path below verifies the independent tool pin.
    function Get-WsmToolFingerprint { 'f'*64 }
    function Assert-Delta([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
    function Get-FixtureHash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
    function New-FixtureRecord([string]$ItemId,[string]$Name,[string]$ContentHash,[string]$LastWrite='2026-10-08T00:00:00.0000000Z'){
        [pscustomobject][ordered]@{ItemId=$ItemId;RelativePath=$Name;Directory=$false;Metadata=[pscustomobject][ordered]@{Sddl='O:SYG:SYD:(A;;FA;;;SY)';MetadataMode='DaclOwner';Attributes=32;CreationUtc='2026-10-08T00:00:00.0000000Z';LastWriteUtc=$LastWrite};Data=[pscustomobject][ordered]@{Bytes=0;Hash=$ContentHash;Chunks=@()}}
    }
    function Write-FixturePackage([string]$Root,$Plan,[string]$PlanHash,[long]$Generation,[string]$BaseHash,[bool]$Final,[object[]]$Rows){
        [void][IO.Directory]::CreateDirectory($Root);$index=Join-Path $Root 'artifacts.jsonl';$writer=New-Object IO.StreamWriter($index,$false,(New-Object Text.UTF8Encoding($false)))
        try{foreach($row in $Rows){$writer.WriteLine((ConvertTo-Json -InputObject $row -Depth 20 -Compress))}}finally{$writer.Dispose()}
        $manifest=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='MigrationPackage';PackageId=[Guid]::NewGuid().ToString();BatchId=$Plan.BatchId;PairId=$Plan.PairId;ApprovalId=$Plan.ApprovalId;PlanHash=$PlanHash;Source=$Plan.Source;Target=$Plan.Target;Generation=$Generation;BaseManifestHash=$BaseHash;Final=$Final;FreezeHash=$(if($Final){'f'*64}else{$null});ArtifactsHash=(Get-FixtureHash $index);CreatedUtc=(Get-WsmUtc);Records=$Rows.Count}
        $manifestPath=Join-Path $Root 'manifest.json';Write-WsmJson $manifestPath $manifest
        [pscustomobject]@{ManifestPath=$manifestPath;ManifestHash=(Get-FixtureHash $manifestPath);IndexPath=$index;Manifest=$manifest}
    }
    function Invoke-FixtureDelta($Base,$Current,$Plan,[string]$PlanPath,[string]$PlanHash,[string]$OutputPath,[string]$SummaryPath,[string[]]$Owned){
        New-WsmArtifactDeltaManifest -BaseManifestPath $Base.ManifestPath -BaseManifestHash $Base.ManifestHash -BasePlanPath $PlanPath -BasePlanHash $PlanHash -CurrentManifestPath $Current.ManifestPath -CurrentManifestHash $Current.ManifestHash -CurrentPlanPath $PlanPath -CurrentPlanHash $PlanHash -OutputPath $OutputPath -SummaryPath $SummaryPath -OwnedItemIds $Owned
    }
    function New-FixtureReboundSummary([string]$SourceSummary,[string]$ChangesPath,[string]$SummaryPath){
        $value=Read-WsmJson $SourceSummary;$value.ChangesHash=Get-FixtureHash $ChangesPath;Write-WsmJson $SummaryPath $value;Get-FixtureHash $SummaryPath
    }
    function Write-FixtureReorderedChanges([string]$SourcePath,[string]$DestinationPath,[switch]$DuplicateFirst){
        $reader=New-Object IO.StreamReader($SourcePath,[Text.Encoding]::UTF8,$true);$writer=New-Object IO.StreamWriter($DestinationPath,$false,(New-Object Text.UTF8Encoding($false)))
        try{$first=$reader.ReadLine();$second=$reader.ReadLine();if($null -eq $first -or $null -eq $second){throw 'Fixture requires two change rows.'};if($DuplicateFirst){$writer.WriteLine($first);$writer.WriteLine($first);$writer.WriteLine($second)}else{$writer.WriteLine($second);$writer.WriteLine($first)};while($null -ne ($line=$reader.ReadLine())){$writer.WriteLine($line)}}finally{$reader.Dispose();$writer.Dispose()}
    }
    $root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-test-delta-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
    try{
        $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint='a'*64;Name='source'};$target=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint='b'*64;Name='target'}
        $itemId='1'*64;$spec=[pscustomobject][ordered]@{Adapter='FileScope';Owner='fixture owner';Evidence='fixture scope';SourcePath=(Join-Path $root 'source-scope');TargetPath=(Join-Path $root 'target-scope');ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';ConflictPolicy='Block'}
        $plan=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='MigrationPlan';BatchId=[Guid]::NewGuid().ToString();PairId=[Guid]::NewGuid().ToString();ApprovalId=[Guid]::NewGuid().ToString();Source=$source;Target=$target;Mode='IsolatedPilot';ToolFingerprint=(Get-WsmToolFingerprint);Items=@([pscustomobject]@{ItemId=$itemId;Decision='Include';MigrationSpec=$spec})}
        $planPath=Join-Path $root 'plan.json';Write-WsmJson $planPath $plan;$planHash=Get-FixtureHash $planPath
        $emptyHash=(Get-WsmHashText '')
        # Cross the 5,000-record run boundary while including all change classes.
        $baseRows=New-Object 'System.Collections.Generic.List[object]';$currentRows=New-Object 'System.Collections.Generic.List[object]'
        for($n=0;$n -lt 5004;$n++){
            $name=('record-{0:D5}.dat' -f $n);$hash=$emptyHash;$baseRows.Add((New-FixtureRecord $itemId $name $hash))
            if($n -eq 1){$currentRows.Add((New-FixtureRecord $itemId $name ('a'*64)))}
            elseif($n -eq 2){$currentRows.Add((New-FixtureRecord $itemId $name $hash '2026-10-08T01:00:00.0000000Z'))}
            elseif($n -ne 3){$currentRows.Add((New-FixtureRecord $itemId $name $hash))}
        }
        $currentRows.Add((New-FixtureRecord $itemId 'record-added.dat' $emptyHash))
        $baseRoot=Join-Path $root 'base';$base=Write-FixturePackage $baseRoot $plan $planHash 1 '' $false $baseRows.ToArray()
        $currentRoot=Join-Path $root 'current';$current=Write-FixturePackage $currentRoot $plan $planHash 2 $base.ManifestHash $true $currentRows.ToArray()
        $changes=Join-Path $root 'changes.jsonl';$summary=Join-Path $root 'delta.json'
        $made=Invoke-FixtureDelta $base $current $plan $planPath $planHash $changes $summary @($itemId)
        Assert-Delta ($made.Valid -and $made.ChangeCount -eq 5005) 'Large delta was not produced.'
        Assert-Delta ($made.Counts.Added -eq 1 -and $made.Counts.Modified -eq 1 -and $made.Counts.MetadataOnly -eq 1 -and $made.Counts.Deleted -eq 1 -and $made.Counts.Unchanged -eq 5001) 'Delta did not classify add/modify/metadata/delete/unchanged exactly.'
        $valid=Test-WsmArtifactDeltaManifest -SummaryPath $summary -SummaryHash $made.SummaryHash -ChangesPath $changes -BaseManifestPath $base.ManifestPath -BaseManifestHash $base.ManifestHash -BasePlanPath $planPath -BasePlanHash $planHash -CurrentManifestPath $current.ManifestPath -CurrentManifestHash $current.ManifestHash -CurrentPlanPath $planPath -CurrentPlanHash $planHash
        Assert-Delta $valid.Valid 'Generated delta did not validate.'
        foreach($case in @('duplicate','reordered')){$caseRoot=Join-Path $root ('changes-'+$case);[void][IO.Directory]::CreateDirectory($caseRoot);$caseChanges=Join-Path $caseRoot 'changes.jsonl';$caseSummary=Join-Path $caseRoot 'summary.json';Write-FixtureReorderedChanges $changes $caseChanges -DuplicateFirst:($case -eq 'duplicate');$caseSummaryHash=New-FixtureReboundSummary $summary $caseChanges $caseSummary;$blocked=$false
            try{Test-WsmArtifactDeltaManifest -SummaryPath $caseSummary -SummaryHash $caseSummaryHash -ChangesPath $caseChanges -BaseManifestPath $base.ManifestPath -BaseManifestHash $base.ManifestHash -BasePlanPath $planPath -BasePlanHash $planHash -CurrentManifestPath $current.ManifestPath -CurrentManifestHash $current.ManifestHash -CurrentPlanPath $planPath -CurrentPlanHash $planHash|Out-Null}catch{$blocked=$_.Exception.Message -match 'strictly sorted'}
            Assert-Delta $blocked ('Duplicate/reordered change keys were not rejected by the streaming order check: '+$case)
        }
        $hugeChangesRoot=Join-Path $root 'huge-changes';[void][IO.Directory]::CreateDirectory($hugeChangesRoot);$hugeChanges=Join-Path $hugeChangesRoot 'changes.jsonl';[IO.File]::WriteAllText($hugeChanges,('{'+('x'*1048577)+'}'+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)));$hugeSummary=Join-Path $hugeChangesRoot 'summary.json';$hugeSummaryHash=New-FixtureReboundSummary $summary $hugeChanges $hugeSummary;$blocked=$false
        try{Test-WsmArtifactDeltaManifest -SummaryPath $hugeSummary -SummaryHash $hugeSummaryHash -ChangesPath $hugeChanges -BaseManifestPath $base.ManifestPath -BaseManifestHash $base.ManifestHash -BasePlanPath $planPath -BasePlanHash $planHash -CurrentManifestPath $current.ManifestPath -CurrentManifestHash $current.ManifestHash -CurrentPlanPath $planPath -CurrentPlanHash $planHash|Out-Null}catch{$blocked=$_.Exception.Message -match 'bounded line limit'}
        Assert-Delta $blocked 'A trusted but oversized ChangesPath row was read before its bound was enforced.'
        $hugeIndexRoot=Join-Path $root 'huge-index';$hugeIndexPkg=Write-FixturePackage $hugeIndexRoot $plan $planHash 2 $base.ManifestHash $true @();[IO.File]::WriteAllText($hugeIndexPkg.IndexPath,('{'+('x'*1048577)+'}'+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)));$hugeManifest=Read-WsmJson $hugeIndexPkg.ManifestPath;$hugeManifest.ArtifactsHash=Get-FixtureHash $hugeIndexPkg.IndexPath;Write-WsmJson $hugeIndexPkg.ManifestPath $hugeManifest;$hugeManifestHash=Get-FixtureHash $hugeIndexPkg.ManifestPath;$blocked=$false
        try{Invoke-FixtureDelta $base ([pscustomobject]@{ManifestPath=$hugeIndexPkg.ManifestPath;ManifestHash=$hugeManifestHash}) $plan $planPath $planHash (Join-Path $root 'huge-index-out.jsonl') (Join-Path $root 'huge-index-out.json') @($itemId)|Out-Null}catch{$blocked=$_.Exception.Message -match 'bounded line limit'}
        Assert-Delta $blocked 'A trusted but oversized raw artifact index row was read before its bound was enforced.'
        $wrongPlan=ConvertFrom-WsmJson ($plan | ConvertTo-Json -Depth 40 -Compress);$wrongPlan.ToolFingerprint='e'*64;$wrongPlanPath=Join-Path $root 'wrong-tool-plan.json';Write-WsmJson $wrongPlanPath $wrongPlan;$wrongPlanHash=Get-FixtureHash $wrongPlanPath
        $wrongPlanRoot=Join-Path $root 'wrong-tool-package';[void][IO.Directory]::CreateDirectory($wrongPlanRoot);$wrongManifest=ConvertFrom-WsmJson ($base.Manifest | ConvertTo-Json -Depth 40 -Compress);$wrongManifest.PlanHash=$wrongPlanHash;$wrongManifestPath=Join-Path $wrongPlanRoot 'manifest.json';Write-WsmJson $wrongManifestPath $wrongManifest;[IO.File]::Copy($base.IndexPath,(Join-Path $wrongPlanRoot 'artifacts.jsonl'))
        $blocked=$false;try{Read-WsmDeltaInput $wrongManifestPath (Get-FixtureHash $wrongManifestPath) $wrongPlanPath $wrongPlanHash|Out-Null}catch{$blocked=$_.Exception.Message -match 'tool plan'}
        Assert-Delta $blocked 'A plan with a wrong pinned tool fingerprint was accepted.'
        $delete=Read-WsmJson $summary;Assert-Delta ($delete.BaseGeneration -eq 1 -and $delete.CurrentGeneration -eq 2 -and $delete.BaseIndexHash -eq $base.Manifest.ArtifactsHash -and $delete.CurrentIndexHash -eq $current.Manifest.ArtifactsHash) 'Summary omitted exact generation/index bindings.'
        # Case-only collision within a trusted current index must be rejected.
        $caseRows=@((New-FixtureRecord $itemId 'Case.dat' $emptyHash),(New-FixtureRecord $itemId 'case.dat' $emptyHash))
        $casePkg=Write-FixturePackage (Join-Path $root 'case') $plan $planHash 2 $base.ManifestHash $true $caseRows
        $blocked=$false;try{Invoke-FixtureDelta $base $casePkg $plan $planPath $planHash (Join-Path $root 'case-out.jsonl') (Join-Path $root 'case-out.json') @($itemId)|Out-Null}catch{$blocked=$_.Exception.Message -match 'Duplicate|case|collision'}
        Assert-Delta $blocked 'Case-insensitive duplicate path was accepted.'
        # A trusted caller hash cannot bless an index changed after the manifest was sealed.
        $drift=Write-FixturePackage (Join-Path $root 'drift') $plan $planHash 2 $base.ManifestHash $true @((New-FixtureRecord $itemId 'x.dat' $emptyHash))
        [IO.File]::AppendAllText($drift.IndexPath,"`n",(New-Object Text.UTF8Encoding($false)))
        $blocked=$false;try{Invoke-FixtureDelta $base $drift $plan $planPath $planHash (Join-Path $root 'drift-out.jsonl') (Join-Path $root 'drift-out.json') @($itemId)|Out-Null}catch{$blocked=$_.Exception.Message -match 'hash'}
        Assert-Delta $blocked 'Changed artifact index was accepted.'
        $wrongBase=Write-FixturePackage (Join-Path $root 'wrong-base') $plan $planHash 2 ('c'*64) $true $currentRows.ToArray()
        $blocked=$false;try{Invoke-FixtureDelta $base $wrongBase $plan $planPath $planHash (Join-Path $root 'wrong-base.jsonl') (Join-Path $root 'wrong-base.json') @($itemId)|Out-Null}catch{$blocked=$_.Exception.Message -match 'based|generation'}
        Assert-Delta $blocked 'Final package with wrong base-manifest reference was accepted.'
        $wrongGeneration=Write-FixturePackage (Join-Path $root 'wrong-generation') $plan $planHash 3 $base.ManifestHash $true $currentRows.ToArray()
        $blocked=$false;try{Invoke-FixtureDelta $base $wrongGeneration $plan $planPath $planHash (Join-Path $root 'wrong-generation.jsonl') (Join-Path $root 'wrong-generation.json') @($itemId)|Out-Null}catch{$blocked=$_.Exception.Message -match 'generation'}
        Assert-Delta $blocked 'Nonconsecutive generation was accepted.'
        # A deletion outside the explicitly owned FileScope set is rejected.
        $blocked=$false;try{Invoke-FixtureDelta $base $current $plan $planPath $planHash (Join-Path $root 'unowned.jsonl') (Join-Path $root 'unowned.json') @()|Out-Null}catch{$blocked=$_.Exception.Message -match 'owned'}
        Assert-Delta $blocked 'Unowned deletion was accepted.'
        # Summary cannot be checked against another current generation or tampered change bytes.
        [IO.File]::AppendAllText($changes,"`n",(New-Object Text.UTF8Encoding($false)))
        $blocked=$false;try{Test-WsmArtifactDeltaManifest -SummaryPath $summary -SummaryHash $made.SummaryHash -ChangesPath $changes -BaseManifestPath $base.ManifestPath -BaseManifestHash $base.ManifestHash -BasePlanPath $planPath -BasePlanHash $planHash -CurrentManifestPath $current.ManifestPath -CurrentManifestHash $current.ManifestHash -CurrentPlanPath $planPath -CurrentPlanHash $planHash|Out-Null}catch{$blocked=$_.Exception.Message -match 'hash'}
        Assert-Delta $blocked 'Tampered delta changes passed validation.'
        Write-Host 'PASS: trusted plan/pair/index binding, all delta classes, owned-scope delete gate, case collisions, stale index, bounded oversized-row rejection, duplicate/reordered changes rejection, tampered changes, and 5,004-record disk-spooled merge.'
    } finally {if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force}}
} $deltaPath
