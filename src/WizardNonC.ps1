function Get-WsmWizardNonCPreparation {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[object[]]$Jobs=@(),[string]$ManifestSelection='',$CancellationToken=$null)
    Assert-WsmCancellationBoundary $CancellationToken 'NonCPreparationStart'
    if($ManifestSelection -and $ManifestSelection -notmatch '^[a-fA-F0-9]{64}$'){throw '請從工具已核對的最終備份清單選擇材料。'}
    $profile=Read-WsmOutputProfile $Workspace
    if(-not $profile -or $profile.Role -cne 'Manager'){throw 'NonC preparation requires the enrolled organizing workspace.'}
    Assert-WsmId $PairId
    $catalog=Get-WsmCatalog $Workspace $PairId
    $approved=Get-WsmWizardCurrentApprovedPlan $Workspace $PairId $profile $catalog $Jobs
    $missing=New-Object 'System.Collections.Generic.List[object]';$gates=New-Object 'System.Collections.Generic.List[object]'
    $registryRevisionAtStart=[int](Get-WsmAssistiveResourceRegistry $Workspace).Revision
    $current=[ordered]@{PlanPath='';PlanHash='';InventoryHash='';SelectionRevision=0;MaterialRegistryRevision=$registryRevisionAtStart;ManifestPath='';ManifestHash='';Generation=$null;FreezeRecordPath='';FreezeRecordHash='';FreezeEvidencePath='';FreezeEvidenceHash='';NonCItemIds=@()}
    $entries=@();$choices=@();$proofOptions=@();$transferChoices=@();$status='NeedsApproval';$package=$null;$canImport=$false;$canPrepare=$false
    if(-not $approved){$gates.Add([pscustomobject]@{code='ApprovedPlan';message='請先完成這次搬移的管理審閱與核准。'})}
    else{
        $plan=$approved.Plan;if($plan.SchemaVersion -ne 3){throw '此核准內容尚未具備資料搬移所需的審閱格式，請先完成管理準備。'};$current.PlanPath=$approved.Path;$current.PlanHash=$approved.SHA256;$current.InventoryHash=[string]$plan.InventoryHash;$current.SelectionRevision=[int]$plan.Assistive.SourceSelectionsVersion
        $items=@($plan.Items|Where-Object {$_.Decision -ceq 'Include' -and $_.MigrationSpec.Adapter -ceq 'FileScope' -and $_.MigrationSpec.TransferChannel -ceq 'NonC'})
        $current.NonCItemIds=@($items|ForEach-Object {[string]$_.ItemId})
        $includedById=@{};foreach($planItem in @($plan.Items|Where-Object Decision -CEQ 'Include')){$includedById[[string]$planItem.ItemId]=$true}
        $entries=@(foreach($item in $items){
            $consumers=New-Object 'System.Collections.Generic.List[string]';$consumers.Add([string]$item.ItemId)
            foreach($consumer in @($plan.Items|Where-Object Decision -CEQ 'Include')){if($consumer.PSObject.Properties['Dependencies'] -and @($consumer.Dependencies|Where-Object ItemId -CEQ $item.ItemId).Count){$consumers.Add([string]$consumer.ItemId)}}
            if($item.MigrationSpec.PSObject.Properties['SharedResourceImpacts']){foreach($impact in @($item.MigrationSpec.SharedResourceImpacts)){if([string]$impact.ResourceItemId -cne [string]$item.ItemId){continue};foreach($consumerId in @($impact.ConsumerItemIds)){if($includedById.ContainsKey([string]$consumerId)){$consumers.Add([string]$consumerId)}}}}
            [pscustomobject][ordered]@{ItemId=[string]$item.ItemId;Name=[string](ConvertTo-WsmAssistiveSafeValue ([string]$item.Name) 'Name');SourcePath=[string]$item.MigrationSpec.SourcePath;TargetPath=[string]$item.MigrationSpec.TargetPath;Channel='NonC';ConsumerRefs=@($consumers.ToArray()|Sort-Object -Unique);RequiredHumanInputs=@('SourceAccessRoot','TargetAccessRoot','AccountMap')}
        })
        if(-not $items.Count){$status='NotApplicable'}
        else{
            $status='NeedsFinalPackage';$candidates=New-Object 'System.Collections.Generic.List[object]'
            $registry=Get-WsmAssistiveResourceRegistry $Workspace
            foreach($material in @($registry.Materials|Where-Object {$_.PairId -ceq $PairId -and $_.Kind -ceq 'AssistivePackageManifest'})){$candidates.Add([pscustomobject]@{Path=[string]$material.Path;SHA256=[string]$material.SHA256})}
            foreach($job in @($Jobs)){
                if(-not $job -or [string]$job.status -cne 'Succeeded' -or [string]$job.role -cne 'Manager' -or [string]$job.pairId -cne $PairId -or [IO.Path]::GetFullPath([string]$job.workspace) -ine [IO.Path]::GetFullPath($Workspace) -or [string]$job.action -cne 'CheckPackage'){continue}
                foreach($output in @($job.outputs)){if($output.PSObject.Properties['ManifestPath'] -and $output.PSObject.Properties['SHA256']){$candidates.Add([pscustomobject]@{Path=[string]$output.ManifestPath;SHA256=[string]$output.SHA256})}}
            }
            $verified=@{}
            foreach($candidate in $candidates){
                try{
                    Assert-WsmCancellationBoundary $CancellationToken 'NonCPreparationPackage'
                    if($candidate.SHA256 -notmatch '^[a-fA-F0-9]{64}$'){continue};Assert-WsmNoReparse $candidate.Path
                    $tested=Test-WsmMigrationPackage -ManifestPath $candidate.Path -ExpectedHash $candidate.SHA256 -CancellationToken $CancellationToken
                    if($tested.Manifest.PairId -cne $PairId -or $tested.Manifest.PlanHash -ine $approved.SHA256 -or -not $tested.Manifest.Final -or $tested.Plan.InventoryHash -ine $plan.InventoryHash -or [int]$tested.Plan.Assistive.SourceSelectionsVersion -ne $current.SelectionRevision){continue}
                    $verified[$candidate.SHA256.ToLowerInvariant()]=[pscustomobject]@{Path=[IO.Path]::GetFullPath($candidate.Path);SHA256=$candidate.SHA256.ToLowerInvariant();Package=$tested}
                }catch{if($_.Exception.Data['CancellationRequested']){throw};$gates.Add([pscustomobject]@{code='InvalidPackageMaterial';message='已登錄材料缺少檔案、已變動或不符合目前核准，請重新核對原交接材料。'})}
            }
            $choices=@(foreach($row in @($verified.Values|Sort-Object {$_.Package.Manifest.Generation})){[pscustomobject]@{value=$row.SHA256;label=('已核對的第 '+$row.Package.Manifest.Generation+' 次最終備份');generation=[long]$row.Package.Manifest.Generation;path=$row.Path}})
            if($ManifestSelection -and -not $verified.ContainsKey($ManifestSelection.ToLowerInvariant())){throw 'The selected final package is not a verified current material for this migration.'}
            if($ManifestSelection){$selected=$verified[$ManifestSelection.ToLowerInvariant()]}
            elseif($verified.Count -eq 1){$selected=@($verified.Values)[0]}
            else{$selected=$null}
            if(-not $selected){
                if($verified.Count -gt 1){$missing.Add([pscustomobject]@{name='ManifestSelection';label='選擇這次要處理的最終備份';type='choice';required=$true;source='VerifiedCurrentMaterials';reason='有多份有效世代，工具不能替你決定。';options=$choices});$status='NeedsMaterialSelection'}
                else{$gates.Add([pscustomobject]@{code='FinalPackage';message='請從舊主機取得已停止寫入並封存的最終備份，核對交接材料後再繼續。'})}
            }else{
                $package=$selected.Package;$current.ManifestPath=$selected.Path;$current.ManifestHash=$selected.SHA256;$current.Generation=[long]$package.Manifest.Generation
                $current.FreezeRecordPath=Join-Path $package.Root 'freeze.json';$current.FreezeRecordHash=[string]$package.Manifest.FreezeHash
                $freeze=Read-WsmFreezeRecord $current.FreezeRecordPath $current.FreezeRecordHash $plan $approved.SHA256
                $evidenceHash=[string]$freeze.SourceFreezeEvidence.SHA256;$evidenceMatches=@($registry.Materials|Where-Object {$_.PairId -ceq $PairId -and $_.SHA256 -ieq $evidenceHash})
                $validEvidence=@{}
                foreach($material in $evidenceMatches){try{Assert-WsmCancellationBoundary $CancellationToken 'NonCPreparationFreezeEvidence';Assert-WsmNoReparse ([string]$material.Path);$evidence=Assert-WsmSourceFreezeEvidence ([string]$material.Path) $evidenceHash $plan $approved.SHA256 ([string]$freeze.FreezeEpoch);Assert-WsmSourceFreezeEvidenceMatchesAttestation $evidence $freeze|Out-Null;$validEvidence[[IO.Path]::GetFullPath([string]$material.Path)]=[string]$material.Path}catch{if($_.Exception.Data['CancellationRequested']){throw}}}
                if($validEvidence.Count -eq 1){$current.FreezeEvidencePath=@($validEvidence.Values)[0];$current.FreezeEvidenceHash=$evidenceHash}
                else{$missing.Add([pscustomobject]@{name='FreezeEvidenceMaterial';label='提供舊主機已停止寫入的確認資料';type='verifiedFile';required=$true;source='ExternalOwnerEvidence';reason='工具已知應核對的內容指紋，但尚未取得唯一有效的確認檔。';options=@()})}
                $status='NeedsHumanEvidence'
                $optionsList=New-Object 'System.Collections.Generic.List[object]';$seenProofOptions=@{}
                foreach($material in @($registry.Materials|Where-Object {$_.PairId -ceq $PairId})){
                    try{
                        Assert-WsmCancellationBoundary $CancellationToken 'NonCPreparationEvidence'
                        if($material.Kind -notin @('AssistivePeerShareProof','SourcePeerShareProof','TargetPhysicalProof','AssistiveTargetPhysicalProof')){continue}
                        Assert-WsmNoReparse ([string]$material.Path);$proof=Read-WsmTrustedJson ([string]$material.Path) ([string]$material.SHA256)
                        if($proof.Kind -ceq 'AssistivePeerShareProof'){$proof=Read-WsmAssistivePeerShareProof ([string]$material.Path) ([string]$material.SHA256) ([string]$plan.Source.Fingerprint);if($proof.PeerHostId -cne $plan.Source.HostId){continue};$proofKind='SourcePeerShareProof';$proofLabel='已核對的舊主機共享資料夾：'+[string]$proof.PeerName+'／'+[string]$proof.ShareName}
                        elseif($proof.Kind -ceq 'AssistiveTargetPhysicalProof'){
                            Assert-WsmAssistiveTargetPhysicalProof $proof ([string]$proof.TargetPhysicalId) @($proof.PhysicalIdentities)|Out-Null
                            if($proof.TargetHostId -cne $plan.Target.HostId -or $proof.ObserverMachineFingerprint -ine $plan.Target.Fingerprint){continue}
                            $proofKind='TargetPhysicalProof';$proofLabel='已核對的新主機實際儲存位置'
                        }else{continue}
                        $proofOptionKey=$proofKind+'|'+([string]$material.SHA256).ToLowerInvariant();if($seenProofOptions.ContainsKey($proofOptionKey)){continue};$seenProofOptions[$proofOptionKey]=$true
                        $proofTime=if($proofKind -ceq 'SourcePeerShareProof'){[string]$proof.CreatedUtc}else{[string]$proof.ObservedUtc}
                        $displayTime='時間未核驗';$parsedTime=[DateTimeOffset]::MinValue
                        if([DateTimeOffset]::TryParse($proofTime,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsedTime)){$displayTime=$parsedTime.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')}
                        if($proofKind -ceq 'TargetPhysicalProof'){$targetName=if($plan.Target.PSObject.Properties['Name'] -and $plan.Target.Name){[string]$plan.Target.Name}else{[string]$plan.Target.HostId};$proofLabel+='：'+$targetName}
                        $proofLabel+='／'+$displayTime+'／材料 '+([string]$material.SHA256).Substring(0,12)
                        $optionsList.Add([pscustomobject]@{kind=$proofKind;path=[IO.Path]::GetFullPath([string]$material.Path);sha256=[string]$material.SHA256;label=$proofLabel;requiresRootReview=$true})
                    }catch{if($_.Exception.Data['CancellationRequested']){throw}}
                }
                $proofOptions=@($optionsList.ToArray())
                foreach($name in @('SourcePeerShareProof','TargetPhysicalProof','AccountMap')){
                    $label=switch($name){SourcePeerShareProof {'舊主機提供資料的共享資料夾確認'} TargetPhysicalProof {'新主機實際儲存位置確認'} AccountMap {'確認舊帳號對應到新電腦的哪個帳號'}}
                    $available=@($proofOptions|Where-Object kind -CEQ $name)
                    if($name -ceq 'AccountMap' -or $available.Count -ne 1){$missing.Add([pscustomobject]@{name=$name;label=$label;type=$(if($name -ceq 'AccountMap'){'accountMapping'}elseif($available.Count){'choice'}else{'verifiedFile'});required=$true;source='ExternalReviewedEvidence';reason='需要實際觀測或負責人選擇，不能依同名帳號或磁碟代號猜測。';options=$available})}
                }
                # Multiple verified proofs require an explicit selection; they
                # do not make the creation form impossible to open. The create
                # consumer rechecks the exact selected hashes and endpoints.
                $canPrepare=([bool]$current.FreezeEvidencePath -and @($proofOptions|Where-Object kind -CEQ 'SourcePeerShareProof').Count -ge 1 -and @($proofOptions|Where-Object kind -CEQ 'TargetPhysicalProof').Count -ge 1)
                $transferList=New-Object 'System.Collections.Generic.List[object]'
                foreach($material in @($registry.Materials|Where-Object {$_.PairId -ceq $PairId -and $_.Kind -in @('NonCTransferPlan','AssistiveNonCTransferPlan')})){
                    try{
                        Assert-WsmCancellationBoundary $CancellationToken 'NonCPreparationExistingTransfer'
                        if(-not $current.FreezeEvidencePath){continue}
                        $transfer=Assert-WsmAssistiveNonCTransferContext -TransferPlanPath ([string]$material.Path) -TransferPlanHash ([string]$material.SHA256) -SealedPlanPath $current.PlanPath -SealedPlanHash $current.PlanHash -ManifestPath $current.ManifestPath -ManifestHash $current.ManifestHash -FreezeEvidencePath $current.FreezeEvidencePath -FreezeEvidenceHash $current.FreezeEvidenceHash -ImportOnly
                        if($transfer.Plan.Channel -cne 'NonC'){continue}
                        $transferList.Add([pscustomobject]@{path=[IO.Path]::GetFullPath([string]$material.Path);sha256=[string]$material.SHA256;generation=$current.Generation;label='本次最終備份已核對的非 C 槽搬移計畫'})
                    }catch{if($_.Exception.Data['CancellationRequested']){throw}}
                }
                $transferChoices=@($transferList.ToArray())
                if($transferChoices.Count -eq 1){$status='ReadyToImportTransferResult';$canImport=$true;$canPrepare=$false;$missing.Clear();$missing.Add([pscustomobject]@{name='TargetTransferResult';label='讀入新主機的非 C 槽搬移結果';type='verifiedFile';required=$true;source='TargetTransferEvidence';reason='需核對實際搬移結果；已有搬移計畫不等於檔案已完成。';options=@()})}
                elseif($transferChoices.Count -gt 1){$missing.Add([pscustomobject]@{name='TransferSelection';label='選擇要接續的非 C 槽搬移計畫';type='choice';required=$true;source='VerifiedCurrentMaterials';reason='存在多份有效搬移計畫，請確認接續哪一份。';options=$transferChoices})}
            }
        }
    }
    # Never silently select an older valid package when another registered
    # candidate is missing or drifted. Repair the durable material reference
    # before it can authorize either transfer creation or result import.
    if(@($gates.ToArray()|Where-Object code -CEQ 'InvalidPackageMaterial').Count){$status='NeedsMaterialRepair';$canPrepare=$false;$canImport=$false}
    $registryRevisionAtEnd=[int](Get-WsmAssistiveResourceRegistry $Workspace).Revision
    if($registryRevisionAtEnd -ne $registryRevisionAtStart){throw 'NonC preparation materials changed during review; rerun the preparation check.'}
    $preparation=[pscustomobject][ordered]@{Kind='WizardNonCPreparation';PairId=$PairId;Status=$status;Current=[pscustomobject]$current;Entries=$entries;MaterialChoices=$choices;ProofOptions=$proofOptions;TransferChoices=$transferChoices;MissingFields=@($missing.ToArray());Gates=@($gates.ToArray());CanCreateTransferPlan=$canPrepare;CanImportResult=$canImport;HumanConfirmationRequired=$true;ReadOnly=$true;AuthoritativeApproval=$false;ProductionVerified=$false}
    # An already imported, verified receipt consumes the one-shot result gate.
    # Keep durable history visible, but do not offer the same import again.
    if($approved -and $Catalog -and $Catalog.Assistive){$existingResult=Get-WsmWizardNonCResultSummary $Workspace $PairId $approved $preparation $Catalog;if($existingResult.hasDurableRecord){$preparation.CanImportResult=$false;if($preparation.Status -ceq 'ReadyToImportTransferResult'){$preparation.Status='ResultAlreadyImported'}}}
    $preparation
}

function Get-WsmWizardNonCResultSummary([string]$Workspace,[string]$PairId,$ApprovedPlan,$Preparation,$Catalog) {
    $empty=[pscustomobject][ordered]@{Status='AwaitingTargetTransferResult';PairId=$PairId;PlanHash='';ManifestHash='';Generation=$null;hasDurableRecord=$false;current=$false;CStatus='AwaitingVerifiedPackage';NonCStatus='AwaitingTargetTransferResult';NonCResults=@();OverallStatus='Incomplete';CCompleted=$false;NonCCompleted=$false;ContentRead=$false;ProductionVerified=$false}
    if(-not $ApprovedPlan -or -not $ApprovedPlan.Plan -or -not $Preparation -or $Preparation.Kind -cne 'WizardNonCPreparation' -or -not $Catalog -or -not $Catalog.Assistive -or $Preparation.PairId -cne $PairId){return $empty}
    $current=$Preparation.Current
    if([string]$current.PlanHash -ine [string]$ApprovedPlan.SHA256){return $empty}
    if(-not $current.ManifestHash -or -not $current.ManifestPath -or -not $current.Generation -or $current.ManifestHash -notmatch '^[a-fA-F0-9]{64}$'){return $empty}
    $includedItems=@($ApprovedPlan.Plan.Items|Where-Object Decision -CEQ 'Include');$nonCItems=@($includedItems|Where-Object {$_.PSObject.Properties['MigrationSpec'] -and $_.MigrationSpec -and $_.MigrationSpec.Adapter -ceq 'FileScope' -and $_.MigrationSpec.TransferChannel -ceq 'NonC'}|ForEach-Object {[string]$_.ItemId});$cItems=@($includedItems|Where-Object {$_.PSObject.Properties['MigrationSpec'] -and $_.MigrationSpec -and $_.MigrationSpec.Adapter -ceq 'FileScope' -and $_.MigrationSpec.TransferChannel -ceq 'C'}|ForEach-Object {[string]$_.ItemId});$configItems=New-Object 'System.Collections.Generic.List[string]';$certificateItems=New-Object 'System.Collections.Generic.List[string]';$manualItems=New-Object 'System.Collections.Generic.List[string]';$unsupportedItems=New-Object 'System.Collections.Generic.List[string]';$matrix=@{};foreach($adapter in @(Get-WsmAdapterMatrix)){$matrix[[string]$adapter.Adapter]=$adapter};foreach($item in $includedItems){$spec=$item.MigrationSpec;if(-not $spec){$unsupportedItems.Add([string]$item.ItemId);continue};if($spec.Adapter -ceq 'ManualWorkflow'){$manualItems.Add([string]$item.ItemId);continue};if($spec.Adapter -ceq 'Certificate'){$certificateItems.Add([string]$item.ItemId);continue};if($spec.Adapter -ceq 'FileScope'){if($spec.TransferChannel -cnotin @('C','NonC')){$unsupportedItems.Add([string]$item.ItemId)};continue};if($matrix.ContainsKey([string]$spec.Adapter) -and [bool]$matrix[[string]$spec.Adapter].ExportImplemented){$configItems.Add([string]$item.ItemId)}else{$unsupportedItems.Add([string]$item.ItemId)}}
    $base=[ordered]@{Status='VerifiedControlPackageAvailable';PairId=$PairId;PlanHash=[string]$current.PlanHash;ManifestHash=[string]$current.ManifestHash;Generation=[long]$current.Generation;InventoryHash=[string]$current.InventoryHash;SelectionRevision=[int]$current.SelectionRevision;hasDurableRecord=$false;current=$true;CStatus=$(if($cItems.Count){'VerifiedPackageAvailable'}else{'NoIncludedCFileScope'});CIncludedItemIds=$cItems;CIncludedItemCount=$cItems.Count;CManifestPath=[IO.Path]::GetFullPath([string]$current.ManifestPath);CManifestHash=[string]$current.ManifestHash;CCompleted=($cItems.Count -gt 0);ConfigurationEvidenceStatus=$(if($configItems.Count){'VerifiedInSealedPlanAndDelivered'}else{'NoIncludedSupportedConfiguration'});ConfigurationItemIds=@($configItems.ToArray());CertificateStatus=$(if($certificateItems.Count){'VerifiedPayloadDelivered'}else{'NoIncludedCertificate'});CertificateItemIds=@($certificateItems.ToArray());ManualArtifactsNotSupported=@($manualItems.ToArray());UnsupportedIncludedItemIds=@($unsupportedItems.ToArray());NonCStatus=$(if($nonCItems.Count){'AwaitingTargetTransferResult'}else{'NoIncludedNonCItems'});NonCItemIds=$nonCItems;NonCResults=@();NonCCompleted=$false;OverallStatus='VerifiedControlPackageAvailable';ContentRead=$false;ProductionVerified=$false}
    if(-not $nonCItems.Count){if($manualItems.Count -or $unsupportedItems.Count){$base.Status='ReviewRequired';$base.OverallStatus='ReviewRequired'};return [pscustomobject]$base}
    $transfers=New-Object 'System.Collections.Generic.List[object]'
    foreach($choice in @($Preparation.TransferChoices)){
        if(-not $choice -or [string]$choice.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or [string]$choice.generation -ne [string]$current.Generation){continue}
        try{
            $path=[IO.Path]::GetFullPath([string]$choice.path);$materialRoot=[IO.Path]::GetFullPath((Join-Path (Join-Path (Join-Path $Workspace 'workspace-control') 'wizard-materials') ('nonc-'+$PairId))).TrimEnd('\')+'\'
            if(-not $path.StartsWith($materialRoot,[StringComparison]::OrdinalIgnoreCase)){continue};Assert-WsmNoReparse $path;Assert-WsmTrustedFile $path ([string]$choice.sha256)
            $transfer=Assert-WsmAssistiveNonCPlan $null $path ([string]$choice.sha256)
            if($transfer.PairId -cne $PairId -or $transfer.SealedPlanHash -ine [string]$current.PlanHash -or $transfer.ManifestHash -ine [string]$current.ManifestHash -or [long]$transfer.Generation -ne [long]$current.Generation -or $transfer.Channel -cne 'NonC' -or $transfer.SourceInventoryHash -ine [string]$current.InventoryHash -or [int]$transfer.SelectionRevision -ne [int]$current.SelectionRevision -or $transfer.FreezeEpoch -cne [string]$transfer.FreezeProof.FreezeEpoch){continue}
            $transfers.Add([pscustomobject]@{Path=$path;Hash=([string]$choice.sha256).ToLowerInvariant();Plan=$transfer})
        }catch{continue}
    }
    $verifiedResults=New-Object 'System.Collections.Generic.List[object]'
    foreach($reference in @($Catalog.Assistive.ResultReferences)){
        if(-not $reference -or [string]$reference.Channel -cne 'NonC' -or [string]$reference.PlanHash -ine [string]$current.PlanHash -or [string]$reference.ManifestHash -ine [string]$current.ManifestHash -or [long]$reference.Generation -ne [long]$current.Generation){continue}
        $transferMatches=@($transfers|Where-Object {$_.Plan.TransferId -ceq [string]$reference.TransferId -and $_.Plan.MetadataPolicyHash -ieq [string]$reference.MetadataPolicyHash -and $_.Plan.TargetPhysicalId -ceq [string]$reference.TargetPhysicalId -and $_.Plan.FreezeEpoch -ceq [string]$reference.FreezeEpoch})
        if($transferMatches.Count -ne 1){continue}
        $relative=[string]$reference.Reference
        if($relative -notmatch '^assistive/results/[a-f0-9]{64}\.json$' -or [string]$reference.SHA256 -notmatch '^[a-fA-F0-9]{64}$'){continue}
        $resultPath=[IO.Path]::GetFullPath((Join-Path $Workspace ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))))
        $resultRoot=[IO.Path]::GetFullPath((Join-Path $Workspace 'assistive\results')).TrimEnd('\')+'\'
        if(-not $resultPath.StartsWith($resultRoot,[StringComparison]::OrdinalIgnoreCase)){continue}
        try{
            Assert-WsmNoReparse $resultPath;Assert-WsmTrustedFile $resultPath ([string]$reference.SHA256);$result=Read-WsmTrustedJson $resultPath ([string]$reference.SHA256);$transfer=$transferMatches[0].Plan
            if($result.Kind -cne 'AssistiveNonCTransferResult' -or [int]$result.SchemaVersion -ne 3 -or $result.PairId -cne $PairId -or $result.TransferId -cne $transfer.TransferId -or $result.PlanFileHash -ine $transferMatches[0].Hash -or $result.SealedPlanHash -ine [string]$current.PlanHash -or $result.ManifestHash -ine [string]$current.ManifestHash -or [long]$result.Generation -ne [long]$current.Generation -or $result.Channel -cne 'NonC' -or $result.TargetPhysicalId -cne $transfer.TargetPhysicalId -or $result.MetadataPolicyHash -ine $transfer.MetadataPolicyHash -or $result.FreezeEpoch -cne $transfer.FreezeEpoch){continue}
            $rows=@($result.Rows);$entryIds=@($transfer.Entries|ForEach-Object {[string]$_.EntryId});$rowIds=@($rows|ForEach-Object {[string]$_.EntryId});$allowedItemIds=@($transfer.Entries|ForEach-Object {[string]$_.ItemId}|Sort-Object -Unique)
            $rowMapValid=($entryIds.Count -eq $transfer.Entries.Count -and $entryIds.Count -eq @($entryIds|Sort-Object -Unique).Count -and $rowIds.Count -eq $rows.Count -and $rowIds.Count -eq @($rowIds|Sort-Object -Unique).Count -and @($rowIds|Where-Object {$entryIds -cnotcontains $_}).Count -eq 0 -and @($entryIds|Where-Object {$rowIds -cnotcontains $_}).Count -eq 0 -and @($rows|Where-Object {$allowedItemIds -cnotcontains [string]$_.ItemId}).Count -eq 0)
            foreach($row in $rows){if(-not $rowMapValid){break};$entryMatches=@($transfer.Entries|Where-Object EntryId -CEQ ([string]$row.EntryId));if($entryMatches.Count -ne 1){$rowMapValid=$false;break};$entry=$entryMatches[0];foreach($field in @('ItemId','EntryType','RelativePath','SourcePath','OriginalSourcePath','SourcePeerFingerprint','SourcePeerProofHash','SourceSHA256','TargetPath','TargetPhysicalIdentity','RequireSacl')){if(-not $row.PSObject.Properties[$field] -or [string]$row.$field -cne [string]$entry.$field){$rowMapValid=$false;break}};if(-not $rowMapValid){break};$rowConsumers=@($row.ConsumerRefs|ForEach-Object {[string]$_}|Sort-Object -Unique);$entryConsumers=@($entry.ConsumerRefs|ForEach-Object {[string]$_}|Sort-Object -Unique);if(($rowConsumers -join '|') -cne ($entryConsumers -join '|')){$rowMapValid=$false;break};$rowMap=ConvertTo-WsmAssistiveAccountMap $row.AccountMap;$entryMap=ConvertTo-WsmAssistiveAccountMap $entry.AccountMap;if(($rowMap|ConvertTo-Json -Depth 8 -Compress) -cne ($entryMap|ConvertTo-Json -Depth 8 -Compress)){$rowMapValid=$false;break};if([string]$row.Status -notin @('Applied','BlockedConflict','DeferredManual') -or -not [string]$row.Reason){$rowMapValid=$false;break};if($entry.EntryType -ceq 'File'){if([string]$row.Status -ceq 'Applied' -and ([long]$row.Bytes -ne [long]$entry.Bytes -or [string]$row.SHA256 -ine [string]$entry.SourceSHA256)){$rowMapValid=$false;break};if([long]$row.Bytes -gt [long]$entry.Bytes -or ([string]$row.SHA256 -and [string]$row.SHA256 -ine [string]$entry.SourceSHA256)){$rowMapValid=$false;break}}elseif([long]$row.Bytes -ne 0 -or [string]$row.SHA256){$rowMapValid=$false;break}}
            $applied=@($rows|Where-Object Status -CEQ 'Applied').Count;$blocked=@($rows|Where-Object Status -CEQ 'BlockedConflict').Count;$deferred=@($rows|Where-Object Status -CEQ 'DeferredManual').Count
            if(-not $rowMapValid -or $rows.Count -ne $transfer.Entries.Count -or $applied -ne [int]$reference.Applied -or $blocked -ne [int]$reference.BlockedConflict -or $deferred -ne [int]$reference.DeferredManual -or ($applied+$blocked+$deferred) -ne $rows.Count){continue}
            $verifiedResults.Add([pscustomobject][ordered]@{TransferId=[string]$transfer.TransferId;TransferPlanHash=[string]$transferMatches[0].Hash;ResultPath=$resultPath;ResultHash=[string]$reference.SHA256;Status=$(if($blocked -or $deferred){'ReviewRequired'}else{'Succeeded'});AppliedCount=$applied;BlockedCount=$blocked;DeferredCount=$deferred;Rows=@(foreach($row in $rows){[pscustomobject]@{ItemId=[string]$row.ItemId;EntryId=[string]$row.EntryId;Status=[string]$row.Status;Reason=[string]$row.Reason;Bytes=[long]$row.Bytes;SHA256=[string]$row.SHA256}});AuthoritativeApproval=$false;ProductionVerified=$false})
        }catch{}
    }
    $summaryRows=@($verifiedResults.ToArray())
    if($summaryRows.Count -eq 1){$base.NonCResults=$summaryRows;$base.hasDurableRecord=$true;$base.NonCStatus=[string]$summaryRows[0].Status;$base.NonCCompleted=($summaryRows[0].Status -ceq 'Succeeded');$base.NonCAppliedCount=[int]$summaryRows[0].AppliedCount;$base.NonCBlockedCount=[int]$summaryRows[0].BlockedCount;$base.NonCDeferredCount=[int]$summaryRows[0].DeferredCount;$hasUnsupportedGap=($manualItems.Count -or $unsupportedItems.Count);$base.Status=if($summaryRows[0].Status -ceq 'Succeeded' -and -not $hasUnsupportedGap){'Complete'}else{'ReviewRequired'};$base.OverallStatus=if($summaryRows[0].Status -ceq 'Succeeded' -and -not $hasUnsupportedGap){if($cItems.Count){'CAndNonCVerified'}else{'NonCVerified_NoIncludedCFileScope'}}elseif($summaryRows[0].Status -ceq 'Succeeded'){'NonCImported_WithManualOrUnsupportedGaps'}else{'NeedsReview_ControlPackageAvailable'}}
    elseif($summaryRows.Count -gt 1){$base.NonCResults=$summaryRows;$base.hasDurableRecord=$true;$base.NonCStatus='AmbiguousDuplicateResults';$base.Status='ReviewRequired';$base.OverallStatus='NeedsReview_DuplicateResultReferences'}
    [pscustomobject]$base
}
