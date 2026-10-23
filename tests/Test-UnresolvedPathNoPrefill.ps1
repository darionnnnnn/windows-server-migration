#requires -Version 5.1
# P3: 來源路徑解析失敗時不預填、不標可信、不判通道、不可核准、不可被 bulk 自動套用。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '../src/WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking 3>$null
$root=Join-Path $env:TEMP ('wsm-p3-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root)
        $script:p3Checks=0
        function Check([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:p3Checks++}
        function Fails([scriptblock]$action){try{& $action|Out-Null}catch{return [string]$_.Exception.Message};return $null}
        function New-Candidate($hostId,[string]$name,[string]$key,$settings){New-WsmItem $hostId Storage PathCandidate $name $key ([pscustomobject]$settings)}
        function New-Workspace([string]$name,$items,[string]$sourceName){
            $work=Join-Path $Root $name;Initialize-WsmWizardWorkspace $work Manager|Out-Null
            $inventory=New-WsmInventory $script:source 1 @($items);$path=Join-Path $Root ($name+'-inventory.json');Write-WsmJson $path $inventory
            $catalog=Import-WsmInventory $work $path (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash ('p3 '+$name)
            $catalog=Enable-WsmAssistiveMode $work $catalog.PairId $catalog.DecisionRevision
            foreach($item in @($items)){$current=Get-WsmCatalog $work $catalog.PairId;Set-WsmWizardChoice -Workspace $work -PairId $catalog.PairId -Role Manager -ItemId $item.ItemId -Selected $true -ExpectedDecisionRevision $current.DecisionRevision -ExpectedSelectionRevision $current.Assistive.Selections.Revision|Out-Null}
            [pscustomobject]@{Work=$work;PairId=$catalog.PairId}
        }
        $script:source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString('D');Fingerprint=('a'*64);Name='P3 fixture source'}
        $hostId=$script:source.HostId
        $hostile="<script>alert(1)</script>%X%`a password=abc"
        $unresolved=New-Candidate $hostId 'Unresolved variable' 'u1' ([ordered]@{OriginalPath='%APPDATA%\App';ResolvedCandidate='';ResolutionBasis='Unresolved';ResolutionVariables=@('APPDATA')})
        $legacy=New-Candidate $hostId 'Legacy relative' 'u2' ([ordered]@{OriginalPath='..\relative\data';ResolvedCandidate=''})
        $hostileItem=New-Candidate $hostId 'Hostile original' 'u3' ([ordered]@{OriginalPath=$hostile;ResolvedCandidate='';ResolutionBasis='Unresolved';ResolutionVariables=@('X')})
        $machine=New-Candidate $hostId 'Machine resolved' 'c1' ([ordered]@{OriginalPath='%SystemDrive%\MachineData';ResolvedCandidate='C:\MachineData';ResolutionBasis='Machine';ResolutionVariables=@('SystemDrive')})
        $literal=New-Candidate $hostId 'Literal resolved' 'c2' ([ordered]@{OriginalPath='D:\LiteralData';ResolvedCandidate='D:\LiteralData';ResolutionBasis='Literal';ResolutionVariables=@()})
        $legacyGood=New-Candidate $hostId 'Legacy absolute' 'c3' ([ordered]@{OriginalPath='E:\LegacyData';ResolvedCandidate='E:\LegacyData'})
        $all=@($unresolved,$legacy,$hostileItem,$machine,$literal,$legacyGood)
        $ws=New-Workspace 'manager' $all 'main'
        $catalog=Get-WsmCatalog $ws.Work $ws.PairId
        $catItem={param($id)@($catalog.Items|Where-Object ItemId -CEQ $id)[0]}

        # ---- 共用判定
        foreach($case in @(
            @{S=@{OriginalPath='%APPDATA%\App';ResolvedCandidate='';ResolutionBasis='Unresolved'};E=$true;N='Unresolved'},
            @{S=@{OriginalPath='C:\Abs';ResolvedCandidate='C:\Abs';ResolutionBasis='Unresolved'};E=$true;N='Unresolved wins even when a value is present'},
            @{S=@{OriginalPath='..\x';ResolvedCandidate=''};E=$true;N='legacy relative'},
            @{S=@{OriginalPath='%ProgramData%\x';ResolvedCandidate=''};E=$true;N='legacy percent'},
            @{S=@{OriginalPath='C:\a\..\b';ResolvedCandidate=''};E=$true;N='legacy dotdot'},
            @{S=@{OriginalPath='';ResolvedCandidate=''};E=$true;N='legacy empty'},
            @{S=@{OriginalPath='App\Data';ResolvedCandidate=''};E=$true;N='legacy plain relative'},
            @{S=@{OriginalPath='C:Data';ResolvedCandidate=''};E=$true;N='legacy drive-relative'},
            @{S=@{OriginalPath='\\srv';ResolvedCandidate=''};E=$true;N='legacy incomplete UNC'},
            @{S=@{OriginalPath='C:\Old';ResolvedCandidate=''};E=$false;N='legacy absolute original'},
            @{S=@{OriginalPath='\\srv\share\x';ResolvedCandidate=''};E=$false;N='legacy UNC original'},
            @{S=@{OriginalPath='C:\Old';ResolvedCandidate='C:\Old'};E=$false;N='legacy resolved'},
            @{S=@{OriginalPath='%X%';ResolvedCandidate='C:\X';ResolutionBasis='Machine'};E=$false;N='Machine'},
            @{S=@{OriginalPath='D:\L';ResolvedCandidate='D:\L';ResolutionBasis='Literal'};E=$false;N='Literal'},
            @{S=([pscustomobject]@{OriginalPath='..\x';ResolvedCandidate='';ResolutionBasis='Unresolved'});E=$true;N='object settings'})){
            Check ((Test-WsmPathCandidateUnresolved $case.S) -eq $case.E) ('The shared unresolved predicate is wrong for: '+$case.N)
        }

        # ---- 草稿端
        foreach($pair in @(@($unresolved,'Unresolved'),@($legacy,'legacy relative'),@($hostileItem,'hostile'))){
            $draft=Get-WsmMigrationSpecDraft (& $catItem $pair[0].ItemId) $catalog
            Check ($draft.Adapter -ceq 'FileScope' -and $draft.SourcePath -ceq '' -and $draft.TargetPath -ceq '') ('Draft prefilled an unresolved path: '+$pair[1])
            Check (-not $draft.PSObject.Properties['TransferChannel']) ('Draft judged a channel for an unresolved path: '+$pair[1])
            $draft.Owner='Owner';$draft.Evidence='Evidence'
            Check ($null -ne (Fails {Assert-WsmMigrationSpec $draft -Assistive})) ('The existing approval check accepted an empty source path: '+$pair[1])
            Check ($null -ne (Fails {Assert-WsmMigrationSpec $draft})) ('The legacy approval check accepted an empty source path: '+$pair[1])
        }
        $mapped=& $catItem $unresolved.ItemId;$mapped=$mapped|ConvertTo-Json -Depth 20|ConvertFrom-Json;$mapped.Mapping='D:\NewHome\App'
        $mappedDraft=Get-WsmMigrationSpecDraft $mapped $catalog
        Check ($mappedDraft.SourcePath -ceq '' -and $mappedDraft.TargetPath -ceq 'D:\NewHome\App' -and -not $mappedDraft.PSObject.Properties['TransferChannel']) 'An explicit Mapping must still supply TargetPath but must not create a source path or channel.'
        $mappedDraft.Owner='Owner';$mappedDraft.Evidence='Evidence'
        Check ($null -ne (Fails {Assert-WsmMigrationSpec $mappedDraft -Assistive})) 'A mapped target with an unresolved source was approvable.'

        # 對照組：解析成功行為不變
        $d=Get-WsmMigrationSpecDraft (& $catItem $machine.ItemId) $catalog
        Check ($d.SourcePath -ceq 'C:\MachineData' -and $d.TargetPath -ceq 'C:\MachineData' -and $d.TransferChannel -ceq 'C') 'Machine-resolved draft changed.'
        $d=Get-WsmMigrationSpecDraft (& $catItem $literal.ItemId) $catalog
        Check ($d.SourcePath -ceq 'D:\LiteralData' -and $d.TargetPath -ceq 'D:\LiteralData' -and $d.TransferChannel -ceq 'NonC') 'Literal-resolved draft changed.'
        $d=Get-WsmMigrationSpecDraft (& $catItem $legacyGood.ItemId) $catalog
        Check ($d.SourcePath -ceq 'E:\LegacyData' -and $d.TransferChannel -ceq 'NonC') 'Legacy resolved draft changed.'
        $d.Owner='Owner';$d.Evidence='Evidence';$d.ContentSelection='WholeScope'
        Check ($null -eq (Fails {Assert-WsmMigrationSpec $d -Assistive})) 'A resolved draft no longer passes the existing approval check.'

        # ---- 表單端
        foreach($pair in @(@($unresolved,'Unresolved'),@($legacy,'legacy relative'),@($hostileItem,'hostile'))){
            $form=Get-WsmWizardPreparationReview $ws.Work $ws.PairId $pair[0].ItemId
            $target=@($form.FormFields|Where-Object key -CEQ 'TargetPath')
            Check ($target.Count -eq 1 -and $target[0].value -ceq '' -and $target[0].required -and $target[0].editable) ('Unresolved target is not an empty required field: '+$pair[1])
            Check ($target[0].origin -ceq 'NeedsHumanDecision' -and $target[0].provenance.kind -ceq 'UnresolvedSourcePath') ('Unresolved target is not NeedsHumanDecision/UnresolvedSourcePath: '+$pair[1])
            Check (-not @($form.FormFields|Where-Object {$_.origin -ceq 'TrustedSourceInventory' -and $_.key -in @('SourcePath','TargetPath')}).Count) ('Unresolved path was marked as trusted source inventory: '+$pair[1])
            Check (-not @($form.FormFields|Where-Object key -CEQ 'TransferChannel').Count) ('A transfer channel is shown for an unresolved path: '+$pair[1])
            Check ([string]$target[0].provenance.nextStep -match '補登' -and [string]$target[0].provenance.reason -and $target[0].provenance.reviewHash -ceq $form.ReviewHash) ('Provenance lacks reason/next step/review hash: '+$pair[1])
            $message=Fails {Save-WsmWizardPreparationReview $ws.Work $ws.PairId $pair[0].ItemId $form.ReviewHash 'Owner' 'Reviewed' @{TargetPath='D:\NewHome';ContentSelection='WholeScope'}}
            Check ($message -and $message -match 'channel') ('An unresolved source could be saved as a specification: '+$pair[1]+' '+$message)
        }
        $form=Get-WsmWizardPreparationReview $ws.Work $ws.PairId $unresolved.ItemId
        $prov=@($form.FormFields|Where-Object key -CEQ 'TargetPath')[0].provenance
        Check ($prov.originalPath -ceq '%APPDATA%\App') 'Provenance lost the original string.'
        $form=Get-WsmWizardPreparationReview $ws.Work $ws.PairId $hostileItem.ItemId
        $prov=@($form.FormFields|Where-Object key -CEQ 'TargetPath')[0].provenance
        $json=ConvertTo-Json -InputObject $prov -Depth 8 -Compress
        Check ($prov.originalPath -notmatch "[\u0000-\u001f]" -and $prov.originalPath -match '\\u0007' -and $prov.originalPath -match 'password=\[redacted\]' -and $json -notmatch 'password=abc' -and $json -notmatch '<script>') 'Hostile original text was not projected safely (control characters, secret assignment, markup).'
        foreach($ok in @(@($machine,'C:\MachineData'),@($literal,'D:\LiteralData'),@($legacyGood,'E:\LegacyData'))){
            $form=Get-WsmWizardPreparationReview $ws.Work $ws.PairId $ok[0].ItemId
            $target=@($form.FormFields|Where-Object key -CEQ 'TargetPath')[0]
            Check ($target.value -ceq $ok[1] -and $target.origin -ceq 'TrustedSourceInventory' -and $target.provenance.kind -ceq 'TrustedSourceInventory') ('Resolved path control changed: '+$ok[1])
            Check (@($form.FormFields|Where-Object key -CEQ 'TransferChannel')[0].value -ceq $(if($ok[1] -match '^C:'){'C'}else{'NonC'})) ('Resolved channel control changed: '+$ok[1])
        }

        # ---- bulk
        $preview=Get-WsmWizardBulkPreparationPreview -Workspace $ws.Work -PairId $ws.PairId
        foreach($bad in @($unresolved,$legacy,$hostileItem)){
            Check (@($preview.DeferredFields|Where-Object {$_.ItemId -ceq $bad.ItemId -and $_.Field -ceq 'TargetPath' -and $_.Reason -ceq 'RequiredHumanDecision'}).Count -eq 1) 'Bulk did not defer an unresolved path as a required human decision.'
            Check ($bad.ItemId -cnotin @($preview.CandidateItemIds)) 'Bulk listed an unresolved path as an automatic candidate.'
            $review=Get-WsmWizardPreparationReview $ws.Work $ws.PairId $bad.ItemId
            $answers=Get-WsmWizardBulkPreparationNormalizedAnswers $review @('check one')
            Check (-not $answers.Contains('TargetPath') -and -not $answers.Contains('SourcePath')) 'Bulk normalized answers carried an unresolved path as an automatic answer.'
        }
        Check ($preview.ReviewedSourceDefaultsRequired -is [bool]) 'Bulk preview shape changed.'
        # 合成情境：即使 TargetPath 有明確 Mapping 值，標為 NeedsHumanDecision 的欄位也不可成為自動答案。
        $syntheticReview=[pscustomobject]@{ManualReviewRequired=$false;MissingTypedFields=@();Adapter='FileScope';FormFields=@([pscustomobject]@{key='TargetPath';value='D:\NewHome\App';required=$true;editable=$true;origin='NeedsHumanDecision';options=@();type='text'})}
        Check (@(Get-WsmWizardBulkPreparationEligibility $syntheticReview|Where-Object {$_.Field -ceq 'TargetPath'}).Count -ge 1 -and -not (Get-WsmWizardBulkPreparationNormalizedAnswers $syntheticReview @('x')).Contains('TargetPath')) 'A NeedsHumanDecision target with a value was auto-applied by bulk.'

        # ---- 使用者補登實際路徑後可正常走下去（以補登後的解析結果取代未解析項目）
        $fixed=New-Candidate $hostId 'Unresolved variable' 'u1' ([ordered]@{OriginalPath='%APPDATA%\App';ResolvedCandidate='D:\Supplied\App';ResolutionBasis='Literal';ResolutionVariables=@('APPDATA')})
        $ws2=New-Workspace 'manager-fixed' @($fixed) 'fixed'
        $form=Get-WsmWizardPreparationReview $ws2.Work $ws2.PairId $fixed.ItemId
        $target=@($form.FormFields|Where-Object key -CEQ 'TargetPath')[0]
        Check ($target.value -ceq 'D:\Supplied\App' -and $target.origin -ceq 'TrustedSourceInventory') 'A supplied path was not accepted as the source.'
        $saved=Save-WsmWizardPreparationReview $ws2.Work $ws2.PairId $fixed.ItemId $form.ReviewHash 'Owner' 'Supplied path reviewed' @{ContentSelection='WholeScope'}
        $spec=@((Get-WsmCatalog $ws2.Work $ws2.PairId).Items|Where-Object ItemId -CEQ $fixed.ItemId)[0].MigrationSpec
        Check ($saved.SpecHash -match '^[a-f0-9]{64}$' -and $spec.SourcePath -ceq 'D:\Supplied\App' -and $spec.TransferChannel -ceq 'NonC') 'A supplied path did not continue to a saved specification.'
        Write-Output ('PASS: '+$script:p3Checks+' unresolved source path no-prefill checks (predicate, draft, approval, form, bulk, supplied path).')
    } $root
} finally {
    $absolute=[IO.Path]::GetFullPath($root);$prefix=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if(-not $absolute.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Test cleanup escaped the owned temporary root.'}
    Remove-Item -LiteralPath $absolute -Recurse -Force
}
