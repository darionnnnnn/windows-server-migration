Set-StrictMode -Version Latest

# This document is a read-only projection. It is deliberately not accepted by
# any decision, approval, restore, or readiness API.
function Get-WsmConfirmationValue($Object,[string]$Name,$Default=$null) {
    if($null -eq $Object){return $Default}
    if($Object -is [Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]};return $Default}
    $property=$Object.PSObject.Properties[$Name]
    if($property){return $property.Value}
    $Default
}

function ConvertTo-WsmConfirmationSafeText($Value,[int]$MaximumLength=4096) {
    if($null -eq $Value){return ''}
    $text=[string]$Value
    # Retain useful labels while removing common inline secret assignments and
    # credential-bearing URI userinfo. Never read or serialize raw settings.
    $text=[regex]::Replace($text,'(?i)(password|passwd|pwd|secret|token|credential|client_secret|wallet)\s*[:=]\s*([^;\s,]+)','${1}=[REDACTED]')
    $text=[regex]::Replace($text,'(?i)(://)[^/@\s:]+:[^/@\s]+@','$1[REDACTED]@')
    $text=[regex]::Replace($text,'[\x00-\x08\x0B\x0C\x0E-\x1F]',' ')
    if($text.Length -gt $MaximumLength){$text=$text.Substring(0,$MaximumLength)+'…[bounded]'}
    $text
}

function ConvertTo-WsmConfirmationSafeValue($Value) {
    if($null -eq $Value){return ''}
    if($Value -is [bool] -or $Value -is [ValueType]){return $Value}
    if($Value -is [string]){return (ConvertTo-WsmConfirmationSafeText $Value)}
    if($Value -is [Collections.IDictionary]){
        $safe=[ordered]@{}
        foreach($key in @($Value.Keys | Sort-Object)){
            if([string]$key -match '(?i)(password|passwd|pwd|secret|token|credential|connection|string|wallet|private.?key|command|arguments|uninstallstring)'){continue}
            $safe[[string]$key]=ConvertTo-WsmConfirmationSafeValue $Value[$key]
        }
        return [pscustomobject]$safe
    }
    if($Value -is [Array] -or $Value -is [Collections.IList]){return @($Value | ForEach-Object {ConvertTo-WsmConfirmationSafeValue $_})}
    if($Value.PSObject){
        $safe=[ordered]@{}
        foreach($property in $Value.PSObject.Properties){
            if($property.Name -match '(?i)(password|passwd|pwd|secret|token|credential|connection|string|wallet|private.?key|command|arguments|uninstallstring)'){continue}
            $safe[$property.Name]=ConvertTo-WsmConfirmationSafeValue $property.Value
        }
        return [pscustomobject]$safe
    }
    ConvertTo-WsmConfirmationSafeText $Value
}

function ConvertTo-WsmMarkdownCell($Value) {
    $text=ConvertTo-WsmConfirmationSafeText $Value
    $text=[Net.WebUtility]::HtmlEncode($text)
    $text=$text.Replace('|','&#124;').Replace('`','&#96;').Replace('[','&#91;').Replace(']','&#93;').Replace('*','&#42;').Replace('_','&#95;').Replace(':','&#58;').Replace('!','&#33;')
    [regex]::Replace($text,'[\r\n\x00-\x1f]+',' ')
}

function Write-WsmConfirmationTable($Writer,[string[]]$Headers,$Rows) {
    $Writer.WriteLine('| '+($Headers -join ' | ')+' |')
    $Writer.WriteLine('| '+(@($Headers | ForEach-Object {'---'}) -join ' | ')+' |')
    foreach($row in $Rows){$Writer.WriteLine('| '+(@($Headers | ForEach-Object {ConvertTo-WsmMarkdownCell (Get-WsmConfirmationValue $row $_)}) -join ' | ')+' |')}
    $Writer.WriteLine()
}

function Get-WsmConfirmationSoftwareCatalog($Catalog) {
    $source=Get-WsmConfirmationValue $Catalog 'SoftwareCatalog' $null
    $general=Get-WsmConfirmationValue $Catalog 'GeneralHost' $null
    $reviewed=Get-WsmConfirmationValue $general 'SoftwareCatalog' $null
    $selected=$null;$authority='Missing'
    if($null -ne $reviewed){$selected=$reviewed;$authority='GeneralHost'}elseif($null -ne $source){$selected=$source;$authority='SourceInventoryFallback'}
    if($null -ne $selected){
        Assert-WsmSoftwareCatalog $selected | Out-Null
        $expectedProjection=Get-WsmEnvironmentConfirmationInventoryProjectionHash $Catalog
        if($selected.Source.HostId -cne $Catalog.Source.HostId -or $selected.Source.Fingerprint -cne $Catalog.Source.Fingerprint -or [long]$selected.Source.InventoryRevision -ne [long]$Catalog.InventoryRevision -or $selected.Source.InventoryProjectionHash -ine $expectedProjection){throw 'Software catalog does not bind to the current immutable source inventory projection.'}
        return [pscustomobject]@{Catalog=$selected;SourceCount=@((Get-WsmConfirmationValue $source 'Entries' @())).Count;Authority=$authority}
    }
    [pscustomobject]@{Catalog=$null;SourceCount=0;Authority='Missing'}
}

function Get-WsmEnvironmentConfirmationInventoryProjectionHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog)
    $source=[ordered]@{
        Source=[ordered]@{HostId=[string](Get-WsmConfirmationValue $Catalog.Source 'HostId' '');Fingerprint=[string](Get-WsmConfirmationValue $Catalog.Source 'Fingerprint' '')}
        Revision=[long](Get-WsmConfirmationValue $Catalog 'InventoryRevision' 0)
        Items=@(foreach($item in @($Catalog.Items | Where-Object { (Get-WsmConfirmationValue $_ 'Present' $true) -ne $false -and (Get-WsmConfirmationValue $_ 'ManualEntry' $false) -ne $true } | Sort-Object ItemId)){
            [ordered]@{ItemId=[string](Get-WsmConfirmationValue $item 'ItemId' '');Category=[string](Get-WsmConfirmationValue $item 'Category' '');Kind=[string](Get-WsmConfirmationValue $item 'Kind' '');NaturalKey=[string](Get-WsmConfirmationValue $item 'NaturalKey' '');SettingsHash=[string](Get-WsmConfirmationValue $item 'SettingsHash' '');Status=[string](Get-WsmConfirmationValue $item 'Status' '')}
        })
    }
    Get-WsmHashText (ConvertTo-Json -InputObject ([pscustomobject]$source) -Depth 12 -Compress)
}

function Get-WsmEnvironmentConfirmationProjection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog,[ValidateSet('Review','Preparation','Staged','Final','Cutover','Acceptance','Retirement')][string]$Phase='Review',[object]$TargetObservation=$null,[string]$Context='',[object[]]$GeneralHostEvidence=@())

    $softwareBinding=Get-WsmConfirmationSoftwareCatalog $Catalog
    $softwareCatalog=$softwareBinding.Catalog
    $general=Get-WsmConfirmationValue $Catalog 'GeneralHost' $null
    $software=@();$coverage=@();$preparation=@();$requirements=@();$receipts=@();$issues=@();$handoff=@()
    $runtime=New-Object 'System.Collections.Generic.List[object]';$oracle=New-Object 'System.Collections.Generic.List[object]';$windows=New-Object 'System.Collections.Generic.List[object]';$special=New-Object 'System.Collections.Generic.List[object]';$unknown=New-Object 'System.Collections.Generic.List[object]'
    $sourceCount=[int]$softwareBinding.SourceCount
    $catalogCount=0
    if($null -ne $softwareCatalog){
        Assert-WsmSoftwareCatalog $softwareCatalog | Out-Null
        $entries=@(Get-WsmConfirmationValue $softwareCatalog 'Entries' @());$catalogCount=$entries.Count
        $decisions=@(Get-WsmConfirmationValue $general 'SoftwareDecisions' @())
        $decisionIndex=@{}
        foreach($decision in $decisions){$decisionKey=[string](Get-WsmConfirmationValue $decision 'SoftwareId' '');if(-not $decisionIndex.ContainsKey($decisionKey)){$decisionIndex[$decisionKey]=New-Object 'System.Collections.Generic.List[object]'};$decisionIndex[$decisionKey].Add($decision)}
        $n=0
        $software=@(foreach($entry in $entries){
            $matches=@();if($decisionIndex.ContainsKey([string]$entry.SoftwareId)){$matches=$decisionIndex[[string]$entry.SoftwareId].ToArray()}
            $disposition='Unknown';$owner='';$reason='';$evidencePointer=''
            if($matches.Count -eq 1){$disposition=[string](Get-WsmConfirmationValue $matches[0] 'Disposition' 'Unknown');$owner=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $matches[0] 'Owner' '');$reason=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $matches[0] 'Reason' '');$evidencePointer=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $matches[0] 'Evidence' '')}
            elseif($matches.Count -gt 1){$disposition='Unknown';$reason='Duplicate software decision records require owner review.'}
            $row=[ordered]@{
                SoftwareId=[string](Get-WsmConfirmationValue $entry 'SoftwareId' '')
                Name=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $entry 'Name' '')
                Version=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $entry 'Version' '')
                Publisher=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $entry 'Publisher' '')
                Architecture=[string](Get-WsmConfirmationValue $entry 'Architecture' 'Unknown')
                Scope=[string](Get-WsmConfirmationValue $entry 'Scope' 'Unknown')
                SID=[string](Get-WsmConfirmationValue $entry 'SID' '')
                RegistryView=[string](Get-WsmConfirmationValue $entry 'RegistryView' (Get-WsmConfirmationValue $entry 'View' ''))
                Location=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $entry 'Location' '')
                SourceKind=[string](Get-WsmConfirmationValue $entry 'SourceKind' 'Unknown')
                CaptureStatus=[string](Get-WsmConfirmationValue $entry 'CaptureStatus' (Get-WsmConfirmationValue $entry 'Status' 'Unknown'))
                ObservedUtc=[string](Get-WsmConfirmationValue $entry 'ObservedUtc' '')
                CaptureAccountContext=[string](Get-WsmConfirmationValue $entry 'AccountContext' 'Unknown')
                ItemIds=(@(Get-WsmConfirmationValue $entry 'ItemIds' @()) -join ', ')
                ManualEntry=[bool](Get-WsmConfirmationValue $entry 'ManualEntry' ($entry.SourceKind -eq 'OwnerProvided'))
                OwnerEvidence=$(if($entry.SourceKind -eq 'OwnerProvided'){ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $entry 'Evidence' '')}else{''})
                OwnerEvidenceSHA256=[string](Get-WsmConfirmationValue $entry 'EvidenceHash' '')
                OwnerEvidenceUtc=[string](Get-WsmConfirmationValue $entry 'ProvidedUtc' '')
                EvidenceSummary=ConvertTo-WsmConfirmationSafeValue (Get-WsmConfirmationValue $entry 'Evidence' $null)
                Handling=$disposition;Owner=$owner;OwnerReason=$reason;EvidencePointer=$evidencePointer
                SourceEvidencePointer=('SoftwareCatalog#/Entries/'+$n)
                TargetStatus='NotTested'
            }
            $n++
            [pscustomobject]$row
        })
        $coverageInput=@(Get-WsmConfirmationValue $softwareCatalog 'Coverage' @())
        $coverage=@(foreach($probe in $coverageInput){
            [pscustomobject][ordered]@{
                Probe=[string](Get-WsmConfirmationValue $probe 'Probe' 'Unknown')
                Scope=[string](Get-WsmConfirmationValue $probe 'Scope' 'Unknown')
                SID=[string](Get-WsmConfirmationValue $probe 'SID' '')
                View=[string](Get-WsmConfirmationValue $probe 'View' '')
                Status=[string](Get-WsmConfirmationValue $probe 'Status' 'NotTested')
                Count=[long](Get-WsmConfirmationValue $probe 'Count' 0)
                MaxEntries=(Get-WsmConfirmationValue $probe 'MaxEntries' '')
                MetadataBytes=(Get-WsmConfirmationValue $probe 'MetadataBytes' '')
                Budget=ConvertTo-WsmConfirmationSafeValue (Get-WsmConfirmationValue $probe 'Budget' $null)
                ErrorKind=[string](Get-WsmConfirmationValue $probe 'ErrorKind' '')
                ObservedUtc=[string](Get-WsmConfirmationValue $probe 'ObservedUtc' '')
                EvidencePointer=[string](Get-WsmConfirmationValue $probe 'EvidencePointer' '')
                NextStep=$(if((Get-WsmConfirmationValue $probe 'Status' 'NotTested') -in @('Success','NotInstalled')){'Owner review; empty successful probe is not global proof'}else{'Owner must resolve this coverage gap'})
            }
        })
        for($entryPosition=0;$entryPosition -lt $entries.Count;$entryPosition++){
            $entry=$entries[$entryPosition]
            $kind=[string](Get-WsmConfirmationValue $entry 'SourceKind' '')
            if($kind -match '(?i)(runtime|dotnet|framework|java|python|node|php|powershell|module|odbc|oledb|driver|com|iis|feature|role)'){
                $runtime.Add([pscustomobject][ordered]@{SoftwareId=$entry.SoftwareId;Name=ConvertTo-WsmConfirmationSafeText $entry.Name;Version=ConvertTo-WsmConfirmationSafeText $entry.Version;Architecture=$entry.Architecture;Scope=$entry.Scope;SID=$entry.SID;SourceKind=$kind;EvidencePointer=('SoftwareCatalog#/Entries/'+$entryPosition);Status='Observed metadata only; target installation and account-context test NotTested'})
            }
            if((Get-WsmConfirmationValue $entry 'Architecture' 'Unknown') -eq 'Unknown' -or -not (Get-WsmConfirmationValue $entry 'Version' '')){
                $unknown.Add([pscustomobject][ordered]@{Type='SoftwareMetadata';SoftwareId=$entry.SoftwareId;Name=ConvertTo-WsmConfirmationSafeText $entry.Name;MissingFields=(@(if($entry.Architecture -eq 'Unknown'){'Architecture'};if(-not $entry.Version){'Version'})) -join ', ';Status='Unknown';Owner='Application owner to provide independent evidence'})
            }
            try {if(Test-WsmGeneralHostSpecialSoftware $entry){$decisionRow=@();if($decisionIndex.ContainsKey([string]$entry.SoftwareId)){$decisionRow=$decisionIndex[[string]$entry.SoftwareId].ToArray()};$special.Add([pscustomobject][ordered]@{SoftwareId=$entry.SoftwareId;Name=ConvertTo-WsmConfirmationSafeText $entry.Name;Version=ConvertTo-WsmConfirmationSafeText $entry.Version;SourceKind=$kind;Handling=$(if($decisionRow.Count){$decisionRow[0].Disposition}else{'Unknown'});Owner='External product owner';Status='External process required; no automatic product migration'})}}catch{}
        }
        $preparationInput=@(Get-WsmConfirmationValue $softwareCatalog 'PreparationRequirements' @())
        $softwareById=@{};foreach($entry in $entries){$softwareById[[string]$entry.SoftwareId]=$entry}
        $preparationBySoftwareId=@{};foreach($typed in @(Get-WsmConfirmationValue $general 'Requirements' @())){if((Get-WsmConfirmationValue $typed 'Type' '') -eq 'Preparation' -and (Get-WsmConfirmationValue $typed 'RequiredPhase' '') -eq 'PreparationReady'){$providerId=[string](Get-WsmConfirmationValue $typed 'ProviderSoftwareId' '');if($providerId){if(-not $preparationBySoftwareId.ContainsKey($providerId)){$preparationBySoftwareId[$providerId]=New-Object 'System.Collections.Generic.List[object]'};$preparationBySoftwareId[$providerId].Add($typed)}}}
        $preparation=@(foreach($candidate in $preparationInput){
            $softwareId=[string](Get-WsmConfirmationValue $candidate 'SoftwareId' '')
            $requirement=$null
            $typedMatches=@();if($preparationBySoftwareId.ContainsKey($softwareId)){$typedMatches=$preparationBySoftwareId[$softwareId].ToArray();if($typedMatches.Count -eq 1){$requirement=$typedMatches[0]}}
            $proof=Get-WsmConfirmationValue (Get-WsmConfirmationValue $requirement 'Context' $null) 'PreparationEvidence' $null
            $entryName='';if($softwareById.ContainsKey($softwareId)){$entryName=ConvertTo-WsmConfirmationSafeText $softwareById[$softwareId].Name}
            $consumerIds=New-Object 'System.Collections.Generic.List[string]';foreach($consumerId in @(Get-WsmConfirmationValue $candidate 'ConsumerItemIds' @())){if(-not [string]::IsNullOrWhiteSpace([string]$consumerId) -and -not $consumerIds.Contains([string]$consumerId)){$consumerIds.Add([string]$consumerId)}};foreach($typed in $typedMatches){foreach($consumerId in @(Get-WsmConfirmationValue $typed 'ConsumerItemIds' @())){if(-not [string]::IsNullOrWhiteSpace([string]$consumerId) -and -not $consumerIds.Contains([string]$consumerId)){$consumerIds.Add([string]$consumerId)}}}
            $mediaHash=[string](Get-WsmConfirmationValue $proof 'MediaSHA256' '');if($mediaHash -notmatch '^[a-fA-F0-9]{64}$'){$mediaHash=''}
            $verifyMethod=[string](Get-WsmConfirmationValue $proof 'VerificationMethod' 'NotTested')
            if($verifyMethod -notin @('SignatureVerified','OwnerVerified')){$verifyMethod='NotTested'}
            $supportUtc=[string](Get-WsmConfirmationValue $proof 'VendorSupportCheckedUtc' '');if($supportUtc){try{$supportDate=([DateTime]::Parse($supportUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime();if($supportDate -gt [DateTime]::UtcNow.AddMinutes(5)){$supportUtc='Unknown'}else{$supportUtc=$supportDate.ToString('o')}}catch{$supportUtc='Unknown'}}
            $installOrder=Get-WsmConfirmationValue $proof 'InstallOrder' 'Unknown';$installNumber=[int]0;if(-not [int]::TryParse([string]$installOrder,[ref]$installNumber) -or $installNumber -lt 1){$installOrder='Unknown'}else{$installOrder=$installNumber}
            $isolationHash=[string](Get-WsmConfirmationValue $proof 'IsolationEvidenceSHA256' '');if($isolationHash -notmatch '^[a-fA-F0-9]{64}$'){$isolationHash=''}
            $restartStatus=[string](Get-WsmConfirmationValue $proof 'RestartStatus' 'NotTested');if($restartStatus -notin @('CompletedAndVerified','NotRequired')){$restartStatus='NotTested'}
            $owner=[string](Get-WsmConfirmationValue $candidate 'Owner' (Get-WsmConfirmationValue $requirement 'Owner' ''))
            [pscustomobject][ordered]@{
                PreparationId=[string](Get-WsmConfirmationValue $candidate 'PreparationId' '');SoftwareId=$softwareId
                Name=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $candidate 'Name' $entryName)
                ConsumerItemIds=(@($consumerIds.ToArray() | Sort-Object) -join ', ')
                RequiredVersion=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $requirement 'ExpectedVersion' (Get-WsmConfirmationValue $candidate 'RequiredVersion' 'Unknown'))
                Architecture=[string](Get-WsmConfirmationValue $requirement 'Architecture' (Get-WsmConfirmationValue $candidate 'Architecture' 'Unknown'))
                Scope=[string](Get-WsmConfirmationValue $candidate 'Scope' 'Unknown');Status=[string](Get-WsmConfirmationValue $candidate 'Status' 'NeedsOwnerReview')
                Owner=ConvertTo-WsmConfirmationSafeText $owner;OwnerRequired=([string]::IsNullOrWhiteSpace($owner))
                RequiredPhase=[string](Get-WsmConfirmationValue $requirement 'RequiredPhase' 'PreparationReady')
                PreparationRequirementId=[string](Get-WsmConfirmationValue $requirement 'RequirementId' '')
                MediaReference=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $proof 'MediaReference' '')
                MediaSHA256=$mediaHash;MediaVerificationStatus=$(if($proof){'OwnerEvidenceRecorded'}else{'NotTested'});VerificationMethod=$verifyMethod
                SignatureEvidence=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $proof 'SignatureEvidence' '')
                VendorOSSupportStatus='NotTested'
                VendorOSSupportReference=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $proof 'VendorOSSupportReference' '')
                VendorSupportCheckedUtc=$supportUtc;LicenseStatus=$(if((Get-WsmConfirmationValue $proof 'LicenseReference' '')){'OwnerEvidenceRecorded'}else{'NotTested'});LicenseReference=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $proof 'LicenseReference' '')
                InstallOrder=$installOrder;IsolationEvidenceSHA256=$isolationHash;RestartStatus=$restartStatus
                IsolationStatus=$(if($isolationHash){'OwnerEvidenceRecorded'}else{'NotTested'});RestartPlanStatus=$(if($restartStatus -in @('CompletedAndVerified','NotRequired')){'OwnerEvidenceRecorded'}else{'NotTested'})
                SideEffectsStatus=$(if((Get-WsmConfirmationValue $proof 'SideEffectsReference' '')){'OwnerEvidenceRecorded'}else{'NotTested'});SideEffectsReference=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $proof 'SideEffectsReference' '')
                TargetValidationStatus='NotTested'
                EvidenceStatus=$(if($proof){'Owner-provided evidence fields recorded; target media/support/install remain unverified'}else{'NotTested; owner must provide evidence'})
                EvidencePointer='GeneralHost#/Requirements/Context/PreparationEvidence'
                NextStep='Owner supplies and reviews each evidence reference and confirms media hash/signature or manual verification, vendor OS support/date, install order, license, isolation, restart result and side effects; source-installed software does not prove target support.'
            }
        })
    } else {
        $coverage=@([pscustomobject][ordered]@{Probe='SoftwareCatalog';Scope='All source scopes';SID='';View='';Status='NotTested';Count=0;MaxEntries='';MetadataBytes='';ErrorKind='SourceSoftwareCaptureMissing';ObservedUtc='';EvidencePointer='';NextStep='Capture source software evidence on the enrolled host; missing catalog is not proof of absence'})
        $unknown.Add([pscustomobject][ordered]@{Type='SoftwareCapture';SoftwareId='';Name='Complete source software catalog';MissingFields='All source software and coverage evidence';Status='Unknown';Owner='Source host operator'})
    }

    $itemIndex=0
    $items=@(foreach($item in @($Catalog.Items)){
        $classification=Get-WsmConfirmationValue $item 'Classification' $null
        if(-not $classification -and (Get-Command Get-WsmScopeClassification -ErrorAction SilentlyContinue)){try{$classification=Get-WsmScopeClassification $item}catch{}}
        $classDisposition=[string](Get-WsmConfirmationValue $classification 'Disposition' 'Unknown')
        $isPresent=[bool](Get-WsmConfirmationValue $item 'Present' $true)
        $row=[pscustomobject][ordered]@{
            ItemId=[string](Get-WsmConfirmationValue $item 'ItemId' '')
            Category=[string](Get-WsmConfirmationValue $item 'Category' 'Unknown')
            Kind=[string](Get-WsmConfirmationValue $item 'Kind' 'Unknown')
            Name=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $item 'Name' '')
            Present=$isPresent;CaptureStatus=[string](Get-WsmConfirmationValue $item 'Status' 'Unknown')
            NaturalKey=[string](Get-WsmConfirmationValue $item 'NaturalKey' '');SettingsHash=[string](Get-WsmConfirmationValue $item 'SettingsHash' '')
            Classification=$classDisposition;Decision=[string](Get-WsmConfirmationValue $item 'Decision' 'Pending')
            Reason=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $item 'Reason' '')
            Owner=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $item 'Owner' '')
            EvidencePointer=('Catalog#/Items/'+$item.ItemId)
            TargetPath=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $item 'Mapping' '')
            AccountMapping=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $item 'AccountMapping' '')
            EndpointMapping=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $item 'EndpointMapping' '')
            GeneralHostDisposition=[string](Get-WsmConfirmationValue (Get-WsmConfirmationValue $item 'GeneralHostOverride' $null) 'Disposition' 'Unknown')
        }
        if(-not $isPresent){$row | Add-Member NoteProperty RetainedDeletedItem $true}
        if($row.Category -match '(?i)(Windows|System|Environment|Machine)'){$windows.Add([pscustomobject][ordered]@{ItemId=$row.ItemId;Name=$row.Name;Category=$row.Category;Kind=$row.Kind;SourceSummary='Source metadata only';SourceSettingsHash=$row.SettingsHash;TargetSummary='Unknown until target observation';Decision=$row.Decision;GeneralHostDisposition=$row.GeneralHostDisposition;Owner=$row.Owner;ConsumerIds='';Status='NotTested';NextStep='Owner confirms this exact setting, source/effective policy, consumers, restart, readback and rollback'})}
        if($row.Classification -in @('Unknown','SpecialProduct','Preparation')){$unknown.Add([pscustomobject][ordered]@{Type='SourceItem';SoftwareId='';Name=$row.Name;MissingFields=$(if($row.Classification -eq 'Unknown'){'Owner disposition and evidence'}elseif($row.Classification -eq 'Preparation'){'Version/support/install preparation evidence'}else{'External product procedure and affected consumers'});ItemId=$row.ItemId;Status='Unknown';Owner=$row.Owner})}
        $row;$itemIndex++
    })

    if($general){
        $requirementInput=@(Get-WsmConfirmationValue $general 'Requirements' @())
        $requirements=@(foreach($requirement in $requirementInput){
            [pscustomobject][ordered]@{RequirementId=$requirement.RequirementId;Type=$requirement.Type;ProviderSoftwareId=$requirement.ProviderSoftwareId;ProviderItemId=$requirement.ProviderItemId;ExternalId=$requirement.ExternalId;ConsumerItemIds=(@($requirement.ConsumerItemIds) -join ', ');Certainty=$requirement.Certainty;RequiredPhase=$requirement.RequiredPhase;ExpectedVersion=ConvertTo-WsmConfirmationSafeText $requirement.ExpectedVersion;Architecture=$requirement.Architecture;Context=ConvertTo-WsmConfirmationSafeValue $requirement.Context;Owner=ConvertTo-WsmConfirmationSafeText $requirement.Owner;Decision=$requirement.Decision;Reason=ConvertTo-WsmConfirmationSafeText $requirement.DecisionReason;SourceProof=ConvertTo-WsmConfirmationSafeValue $requirement.SourceProof;Status='Candidate until required owner evidence and gate phase are satisfied'}
        })
        $trustedReceipts=@();$trustedReferenceError=''
        if(@($GeneralHostEvidence).Count){try{$trustedReceipts=@(Read-WsmGeneralHostEvidenceReferences $GeneralHostEvidence $Catalog)}catch{$trustedReferenceError='Trusted GeneralHost evidence references failed hash or binding validation.'}}
        $receiptInput=New-Object 'System.Collections.Generic.List[object]'
        foreach($storedReceipt in @(Get-WsmConfirmationValue $general 'EvidenceReceipts' @())){$receiptInput.Add([pscustomobject]@{Origin='Catalog';Receipt=$storedReceipt})}
        foreach($trustedReceipt in $trustedReceipts){$receiptInput.Add([pscustomobject]@{Origin='TrustedEvidenceReference';Receipt=$trustedReceipt})}
        $receipts=@(foreach($receipt in $receiptInput){
            $receiptBody=$receipt.Receipt
            [pscustomobject][ordered]@{Origin=$receipt.Origin;ReceiptId=[string](Get-WsmConfirmationValue $receiptBody 'ReceiptId' '');RequirementIds=(@(Get-WsmConfirmationValue $receiptBody 'RequirementIds' @()) -join ', ');RequirementProjectionHash=[string](Get-WsmConfirmationValue $receiptBody 'RequirementProjectionHash' '');Phase=[string](Get-WsmConfirmationValue $receiptBody 'Phase' '');TargetFingerprint=[string](Get-WsmConfirmationValue $receiptBody 'TargetFingerprint' '');SourceFingerprint=[string](Get-WsmConfirmationValue $receiptBody 'SourceFingerprint' '');InventoryHash=[string](Get-WsmConfirmationValue $receiptBody 'InventoryHash' '');PlanHash=[string](Get-WsmConfirmationValue $receiptBody 'PlanHash' '');ToolFingerprint=[string](Get-WsmConfirmationValue $receiptBody 'ToolFingerprint' '');Context=ConvertTo-WsmConfirmationSafeValue (Get-WsmConfirmationValue $receiptBody 'Context' $null);ObservedUtc=[string](Get-WsmConfirmationValue $receiptBody 'ObservedUtc' '');ExpiresUtc=[string](Get-WsmConfirmationValue $receiptBody 'ExpiresUtc' '');EvidenceKind=[string](Get-WsmConfirmationValue $receiptBody 'EvidenceKind' '');EvidencePathHash=[string](Get-WsmConfirmationValue $receiptBody 'EvidencePathHash' '');Owner=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $receiptBody 'Owner' '');Status='Stored receipt; exact phase/context/fingerprint/expiry/projection still require authoritative validation';EvidencePointer=$(if($receipt.Origin -eq 'Catalog'){'Catalog#/GeneralHost/EvidenceReceipts'}else{'Trusted GeneralHost evidence file'})}
        })
        $phaseProjection=$null
        if($TargetObservation -and $TargetObservation.Status -eq 'Observed' -and (Get-Command Get-WsmGeneralHostReadinessProjection -ErrorAction SilentlyContinue)){
            try{$phaseProjection=Get-WsmGeneralHostReadinessProjection $Catalog $TargetObservation.TargetFingerprint $Context ([string](Get-WsmConfirmationValue $Catalog.Approval 'Hash' '')) $GeneralHostEvidence;$phaseProjection | Add-Member NoteProperty EvidenceSource 'GeneralHost contract and independently hash-verified receipt references';$phaseProjection | Add-Member NoteProperty TargetObservationIsReadinessProof $false;if($trustedReferenceError){$phaseProjection | Add-Member NoteProperty TrustedEvidenceReferenceError $trustedReferenceError}}catch{$phaseProjection=[pscustomobject][ordered]@{Status='NotTested';ErrorKind='ReadinessProjectionFailed';Error='The authoritative readiness projection could not be evaluated.';TargetObservationIsReadinessProof=$false}}
        } else {$phaseProjection=[pscustomobject][ordered]@{Status='NotTested';TargetObservationIsReadinessProof=$false;Reason='An observed target fingerprint is required to calculate GeneralHost phase readiness; an observation never proves readiness.'}}
        if(Get-Command Get-WsmGeneralHostIssues -ErrorAction SilentlyContinue){try{$issues=@(Get-WsmGeneralHostIssues $Catalog ReviewComplete | ForEach-Object {[pscustomobject][ordered]@{Gate=[string]$_.Gate;RequirementId=[string]$_.RequirementId;ConsumerItemId=[string]$_.ConsumerItemId;Issue=ConvertTo-WsmConfirmationSafeText $_.Issue;NextStep='Resolve through the typed owner review/preview flow; this document is not an input'}})}catch{$issues=@([pscustomobject]@{Gate='ReviewComplete';RequirementId='';ConsumerItemId='';Issue='Authoritative issue projection failed.';NextStep='Inspect the protected catalog and owner review flow'})}}
    } else {$phaseProjection=[pscustomobject][ordered]@{Status='NotTested';TargetObservationIsReadinessProof=$false;Reason='GeneralHost requirements and receipts are unavailable.'}}

    foreach($file in @($Catalog.Items | ForEach-Object {Get-WsmConfirmationValue (Get-WsmConfirmationValue $_ 'MigrationSpec' $null) 'ConfigFiles' @()})){
        $oracleBinding=Get-WsmConfirmationValue $file 'OracleClient' $null
        $oracle.Add([pscustomobject][ordered]@{ArtifactId=[string](Get-WsmConfirmationValue $file 'ArtifactId' '');ItemId=[string](Get-WsmConfirmationValue $file 'ItemId' '');ConsumerItemIds=(@(Get-WsmConfirmationValue $file 'ConsumerItemIds' @()) -join ', ');RelativePath=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $file 'RelativePath' (Get-WsmConfirmationValue $file 'SourcePath' ''));TargetPath=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $file 'TargetPath' '');SHA256=[string](Get-WsmConfirmationValue $file 'SHA256' '');Length=(Get-WsmConfirmationValue $file 'Length' '');Encoding=[string](Get-WsmConfirmationValue $file 'Encoding' 'Unknown');Sensitivity=[string](Get-WsmConfirmationValue $file 'Sensitivity' 'Unknown');Owner=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $file 'Owner' '');EvidencePointer=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $file 'EvidencePointer' '');OracleClient=$(if($oracleBinding){'Owner-bound Oracle client configuration'}else{'Reviewed configuration'});Status='Static metadata only; actual target account/provider/DB test NotTested'})
    }

    $targetDiff=[pscustomobject][ordered]@{Status=$(if($TargetObservation){[string]$TargetObservation.Status}else{'NotTested'});TargetObservationRevision=$(if($TargetObservation){[long]$TargetObservation.TargetObservationRevision}else{0});TargetFingerprint=$(if($TargetObservation){[string]$TargetObservation.TargetFingerprint}else{''});ObservationUtc=$(if($TargetObservation){[string]$TargetObservation.ObservedUtc}else{''});ObservationSHA256=$(if($TargetObservation){[string]$TargetObservation.SHA256}else{''});ComparedRows=0;Added=0;Removed=0;Changed=0;Unchanged=0;Uncompared=(@($software).Count+@($items).Count);ReadinessProof=$false;Explanation='Target observation metadata is hash/revision-bound only. No target diff is claimed without an independently validated full observation projection.'}
    $sourceOs=[string](Get-WsmConfirmationValue $Catalog.Source 'OS' '')
    $sourceBuild=[string](Get-WsmConfirmationValue $Catalog.Source 'Build' '')
    foreach($missing in @(
        [pscustomobject]@{Field='Source OS edition / installation type';Value=(Get-WsmConfirmationValue $Catalog.Source 'Edition' '')},
        [pscustomobject]@{Field='Target fingerprint / bootstrap and takeover identity';Value=(Get-WsmConfirmationValue $TargetObservation 'TargetFingerprint' '')},
        [pscustomobject]@{Field='Target OS / build / edition / Core or Desktop / architecture';Value=(Get-WsmConfirmationValue $TargetObservation 'OS' '')},
        [pscustomobject]@{Field='EOS official source / verification date / timezone / deadline';Value=(Get-WsmConfirmationValue $Catalog 'EOSEvidence' '')},
        [pscustomobject]@{Field='Maintenance window / RPO / RTO / rollback and observation period';Value=(Get-WsmConfirmationValue $Catalog 'OperationalWindow' '')},
        [pscustomobject]@{Field='WorkRoot / EnrollmentId / AttemptId / reports and state custody';Value=(Get-WsmConfirmationValue $Catalog 'OutputContext' '')},
        [pscustomobject]@{Field='DeliveryId / transport hash / volume set / target space';Value=(Get-WsmConfirmationValue $Catalog 'DeliveryContext' '')}
    )){if($null -eq $missing.Value -or [string]::IsNullOrWhiteSpace([string]$missing.Value)){$unknown.Add([pscustomobject][ordered]@{Type='EnvironmentContext';SoftwareId='';Name=$missing.Field;MissingFields=$missing.Field;Status='Unknown';Owner='Migration owner and platform owner'})}}
    $handoff=@(
        [pscustomobject][ordered]@{OwnerRole='Application owner';Confirmation='All discovered/manual/excluded software, versions, consumers, Oracle/provider configuration and business validation';Status='NotTested';NextStep='Review every SoftwareId, preparation candidate, required consumer and missing field'},
        [pscustomobject][ordered]@{OwnerRole='Platform / security owner';Confirmation='Target OS/support/EOS, account rights, effective policy, isolation, restart, security baseline and storage controls';Status='NotTested';NextStep='Provide trusted target evidence and confirm policy/reboot readback'},
        [pscustomobject][ordered]@{OwnerRole='External product owner';Confirmation='Special product procedure, license/wallet/private material custody and product-specific recovery';Status='NotTested';NextStep='Provide controlled external evidence reference and expiry'},
        [pscustomobject][ordered]@{OwnerRole='Migration operator / approver';Confirmation='Fresh preview, hash/revision, maintenance window, RPO/RTO, rollback, backup restore, observation and retirement';Status='NotTested';NextStep='Record decisions through authoritative typed workflow; this document is not approval'}
    )
    $runtime=$runtime.ToArray();$oracle=$oracle.ToArray();$windows=$windows.ToArray();$special=$special.ToArray();$unknown=$unknown.ToArray()
    $itemsByCategory=[ordered]@{};foreach($category in @($items | Select-Object -ExpandProperty Category -Unique | Sort-Object)){$itemsByCategory[[string]$category]=@($items | Where-Object Category -CEQ $category).Count}
    $softwareByScope=[ordered]@{};foreach($scope in @($software | Select-Object -ExpandProperty Scope -Unique | Sort-Object)){$softwareByScope[[string]$scope]=@($software | Where-Object Scope -CEQ $scope).Count}
    $counts=[ordered]@{
        Software=$software.Count;SourceSoftwareCatalog=$sourceCount;AuthoritativeSoftwareCatalog=$catalogCount;Coverage=$coverage.Count;Items=$items.Count;PreparationRequirements=$preparation.Count;RuntimeEvidence=$runtime.Count;OracleConfiguration=$oracle.Count;WindowsDecisions=$windows.Count;SpecialProducts=$special.Count;Unknowns=$unknown.Count;Requirements=$requirements.Count;EvidenceReceipts=$receipts.Count;Blockers=$issues.Count;OwnerHandoff=$handoff.Count
        SoftwareByHandling=[pscustomobject][ordered]@{Reinstall=@($software | Where-Object Handling -EQ Reinstall).Count;Portable=@($software | Where-Object Handling -EQ Portable).Count;KeepCompatible=@($software | Where-Object Handling -EQ KeepCompatible).Count;External=@($software | Where-Object Handling -EQ External).Count;NotNeeded=@($software | Where-Object Handling -EQ NotNeeded).Count;Unknown=@($software | Where-Object Handling -EQ Unknown).Count}
        SoftwareByScope=[pscustomobject]$softwareByScope;ItemsByCategory=[pscustomobject]$itemsByCategory
        CoverageByStatus=[pscustomobject][ordered]@{Success=@($coverage | Where-Object Status -EQ Success).Count;Partial=@($coverage | Where-Object Status -EQ Partial).Count;PermissionDenied=@($coverage | Where-Object Status -EQ PermissionDenied).Count;Failed=@($coverage | Where-Object Status -EQ Failed).Count;NotInstalled=@($coverage | Where-Object Status -EQ NotInstalled).Count;NotRequested=@($coverage | Where-Object Status -EQ NotRequested).Count;NotTested=@($coverage | Where-Object Status -EQ NotTested).Count}
        ItemsByDecision=[pscustomobject][ordered]@{Include=@($items | Where-Object Decision -EQ Include).Count;Exclude=@($items | Where-Object Decision -EQ Exclude).Count;Pending=@($items | Where-Object Decision -EQ Pending).Count;Unknown=@($items | Where-Object Decision -EQ Unknown).Count}
    }
    [pscustomobject][ordered]@{
        SchemaVersion=1;Kind='EnvironmentConfirmationProjection';PairId=[string]$Catalog.PairId
        Source=[pscustomobject][ordered]@{HostId=[string]$Catalog.Source.HostId;Fingerprint=[string]$Catalog.Source.Fingerprint;Name=ConvertTo-WsmConfirmationSafeText $Catalog.Source.Name;OS=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $Catalog.Source 'OS' 'Unknown');Build=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $Catalog.Source 'Build' 'Unknown');Edition=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $Catalog.Source 'Edition' 'Unknown');InstallationType=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $Catalog.Source 'InstallationType' 'Unknown');Architecture=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue $Catalog.Source 'Architecture' 'Unknown')}
        CaptureContext=[pscustomobject][ordered]@{CapturedUtc=[string](Get-WsmConfirmationValue (Get-WsmConfirmationValue $softwareCatalog 'CaptureContext' $null) 'CapturedUtc' '');CaptureIdentity=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue (Get-WsmConfirmationValue $softwareCatalog 'CaptureContext' $null) 'CaptureIdentity' 'Unknown');CaptureHost=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue (Get-WsmConfirmationValue $softwareCatalog 'CaptureContext' $null) 'CaptureHost' 'Unknown');PowerShellVersion=ConvertTo-WsmConfirmationSafeText (Get-WsmConfirmationValue (Get-WsmConfirmationValue $softwareCatalog 'CaptureContext' $null) 'PowerShellVersion' 'Unknown');AccountContext='Unknown; capture identity is not an application execution identity';SoftwareCatalogAuthority=$softwareBinding.Authority;SourceCatalogEntryCount=$sourceCount;AuthoritativeCatalogEntryCount=$catalogCount;CatalogProjectionHash=[string](Get-WsmConfirmationValue $softwareCatalog 'CatalogProjectionHash' '')}
        SourceInventoryProjectionHash=(Get-WsmEnvironmentConfirmationInventoryProjectionHash $Catalog)
        InventoryRevision=[long]$Catalog.InventoryRevision;InventoryHash=[string]$Catalog.InventoryHash;DecisionRevision=[long]$Catalog.DecisionRevision;ToolVersion=$script:ToolVersion;Phase=$Phase;PlanHash=[string](Get-WsmConfirmationValue $Catalog.Approval 'Hash' '')
        GeneratedUtc=Get-WsmUtc;TargetObservation=$TargetObservation;TargetDiff=$targetDiff
        Coverage=$coverage;Software=$software;PreparationRequirements=$preparation;RuntimeEvidence=$runtime;OracleConfiguration=$oracle;WindowsDecisions=$windows;Items=$items;SpecialProducts=$special;Unknowns=$unknown;Requirements=$requirements;ReadinessProjection=$phaseProjection;EvidenceReceipts=$receipts;Blockers=$issues;OwnerHandoff=$handoff
        Counts=[pscustomobject]$counts;ProductionQualified=$false;TrustStatement='Hashes bind bytes. This report is not a decision input, target readiness proof, enterprise approval, or production qualification.'
    }
}

function ConvertTo-WsmConfirmationCsvField($Value) {
    if($null -eq $Value){$text=''}elseif($Value -is [string]){$text=$Value}else{$text=ConvertTo-Json -InputObject $Value -Depth 12 -Compress}
    $text=ConvertTo-WsmConfirmationSafeText $text 32768
    if($text -match '^\s*[=+@-]' -or $text -match '^[\t\r\n]'){$text="'$text"}
    '"'+$text.Replace('"','""')+'"'
}

function Get-WsmConfirmationSections($Projection,[string]$DocumentId,[string]$ProjectionHash) {
    $sections=[ordered]@{}
    $sections.Metadata=@(
        [pscustomobject]@{Field='DocumentId';Value=$DocumentId},[pscustomobject]@{Field='ReportProjectionHash';Value=$ProjectionHash},[pscustomobject]@{Field='PairId';Value=$Projection.PairId},[pscustomobject]@{Field='SourceHostId';Value=$Projection.Source.HostId},[pscustomobject]@{Field='SourceFingerprint';Value=$Projection.Source.Fingerprint},[pscustomobject]@{Field='SourceName';Value=$Projection.Source.Name},[pscustomobject]@{Field='SourceOS';Value=$Projection.Source.OS},[pscustomobject]@{Field='SourceBuild';Value=$Projection.Source.Build},[pscustomobject]@{Field='SourceEdition';Value=$Projection.Source.Edition},[pscustomobject]@{Field='SourceInstallationType';Value=$Projection.Source.InstallationType},[pscustomobject]@{Field='SourceArchitecture';Value=$Projection.Source.Architecture},[pscustomobject]@{Field='InventoryRevision';Value=$Projection.InventoryRevision},[pscustomobject]@{Field='DecisionRevision';Value=$Projection.DecisionRevision},[pscustomobject]@{Field='TargetObservationRevision';Value=(Get-WsmConfirmationValue $Projection.TargetObservation 'TargetObservationRevision' 0)},[pscustomobject]@{Field='SourceInventoryProjectionHash';Value=$Projection.SourceInventoryProjectionHash},[pscustomobject]@{Field='InventoryHash';Value=$Projection.InventoryHash},[pscustomobject]@{Field='PlanHash';Value=$Projection.PlanHash},[pscustomobject]@{Field='CaptureContext';Value=$Projection.CaptureContext},[pscustomobject]@{Field='Counts';Value=$Projection.Counts},[pscustomobject]@{Field='ToolVersion';Value=$Projection.ToolVersion},[pscustomobject]@{Field='Phase';Value=$Projection.Phase},[pscustomobject]@{Field='GeneratedUtc';Value=$Projection.GeneratedUtc},[pscustomobject]@{Field='ProductionQualified';Value=$Projection.ProductionQualified},[pscustomobject]@{Field='TrustStatement';Value=$Projection.TrustStatement}
    )
    foreach($name in @('Coverage','Software','PreparationRequirements','RuntimeEvidence','OracleConfiguration','WindowsDecisions','Items','SpecialProducts','Unknowns','Requirements','Blockers','OwnerHandoff')){$sections[$name]=@($Projection.$name)}
    $sections.ReadinessProjection=@($Projection.ReadinessProjection)
    $sections.EvidenceReceipts=@($Projection.EvidenceReceipts)
    $sections.TargetDiff=@($Projection.TargetDiff)
    $sections
}

function Write-WsmEnvironmentConfirmationFiles($Root,$Stem,$Projection,$ProjectionHash,$DocumentId,$TargetRevision) {
    $paths=[ordered]@{Markdown=(Join-Path $Root ($Stem+'.md'));Json=(Join-Path $Root ($Stem+'.json'));Html=(Join-Path $Root ($Stem+'.html'));Text=(Join-Path $Root ($Stem+'.txt'));Csv=(Join-Path $Root ($Stem+'.csv'))}
    foreach($path in $paths.Values){Assert-WsmNoReparse $path;if([IO.File]::Exists($path) -or [IO.Directory]::Exists($path)){throw 'Confirmation document identity already exists; choose a new DocumentId.'}}
    $temporaries=@{};foreach($key in $paths.Keys){$temporaries[$key]=$paths[$key]+'.partial'}
    try {
        $sections=Get-WsmConfirmationSections $Projection $DocumentId $ProjectionHash
        $writer=New-Object IO.StreamWriter($temporaries.Markdown,$false,(New-Object Text.UTF8Encoding($false)))
        try{
            $writer.WriteLine('# Windows Server 環境、軟體與相依確認');$writer.WriteLine()
            $writer.WriteLine('完整受控清單。改 Markdown 或勾選不會變更決策、核准或放行；請使用管理端 typed JSON/CSV preview，核對版本與 hash 後套用。');$writer.WriteLine()
            $writer.WriteLine('未知與覆蓋缺口必須由 owner 補查。安裝清單、靜態 hash、tnsping 或管理員測試不能替代實際帳號／DB／業務與企業資格。勿填密碼、wallet、私鑰或完整連線字串。');$writer.WriteLine()
            $metadata=@(
                [pscustomobject]@{Field='DocumentId';Value=$DocumentId},[pscustomobject]@{Field='PairId';Value=$Projection.PairId},[pscustomobject]@{Field='Source';Value=($Projection.Source.HostId+' / '+$Projection.Source.Fingerprint+' / '+$Projection.Source.Name)},[pscustomobject]@{Field='InventoryRevision / DecisionRevision / TargetObservationRevision';Value=($Projection.InventoryRevision.ToString()+' / '+$Projection.DecisionRevision.ToString()+' / '+$TargetRevision)},[pscustomobject]@{Field='ReportProjectionHash';Value=$ProjectionHash},[pscustomobject]@{Field='SourceInventoryProjectionHash';Value=$Projection.SourceInventoryProjectionHash},[pscustomobject]@{Field='InventoryHash / PlanHash';Value=($Projection.InventoryHash+' / '+$Projection.PlanHash)},[pscustomobject]@{Field='ToolVersion / Phase / GeneratedUtc';Value=($Projection.ToolVersion+' / '+$Projection.Phase+' / '+$Projection.GeneratedUtc)},[pscustomobject]@{Field='Counts';Value=($Projection.Counts | ConvertTo-Json -Compress)},[pscustomobject]@{Field='Qualification';Value='NotTested; production qualification is false'}
            )
            Write-WsmConfirmationTable $writer @('Field','Value') $metadata
            foreach($sectionName in $sections.Keys){
                $writer.WriteLine('## '+$sectionName);$writer.WriteLine();$rows=@($sections[$sectionName])
                if($rows.Count){$headers=@($rows[0].PSObject.Properties.Name);Write-WsmConfirmationTable $writer $headers $rows}else{$writer.WriteLine('0 rows; this does not establish readiness or global absence.');$writer.WriteLine()}
            }
            $writer.WriteLine('## Owner 確認與交接');$writer.WriteLine();$writer.WriteLine('應用、平台、資安與外部產品 owner 需確認完整 coverage、媒體及版本相容性、特殊產品／Oracle 外部材料、有效設定、維護窗／RPO／RTO、停寫與 fencing、回退新資料、backup restore、觀察期與退役批准。此文件不執行設定，也不更新權威決策。')
            $writer.Flush()
        }finally{$writer.Dispose()}

        $document=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='EnvironmentConfirmation';DocumentId=$DocumentId;PairId=$Projection.PairId;InventoryRevision=$Projection.InventoryRevision;DecisionRevision=$Projection.DecisionRevision;TargetObservationRevision=$TargetRevision;SourceInventoryProjectionHash=$Projection.SourceInventoryProjectionHash;ReportProjectionHash=$ProjectionHash;GeneratedUtc=$Projection.GeneratedUtc;Projection=$Projection;Counts=$Projection.Counts;Status='Generated';AuthoritativeDecisionInput=$false;ProductionQualified=$false}
        $json=$document | ConvertTo-Json -Depth 45 -Compress
        if([Text.Encoding]::UTF8.GetByteCount($json) -gt 128MB){throw 'Confirmation JSON exceeds 128 MiB; no artifact was sealed.'}
        [IO.File]::WriteAllText($temporaries.Json,$json,(New-Object Text.UTF8Encoding($false)))

        $writer=New-Object IO.StreamWriter($temporaries.Text,$false,(New-Object Text.UTF8Encoding($false)))
        try{$writer.WriteLine('Windows Server environment, software and dependency confirmation');$writer.WriteLine(('DocumentId: '+$DocumentId+' | Pair: '+$Projection.PairId+' | Inventory: '+$Projection.InventoryRevision+' | Decision: '+$Projection.DecisionRevision+' | Target observation: '+$TargetRevision));$writer.WriteLine(('ReportProjectionHash: '+$ProjectionHash+' | Phase: '+$Projection.Phase+' | ProductionQualified: False'));$writer.WriteLine('Document edits do not update decisions or gates. Unknown and NotTested remain unresolved.');foreach($sectionName in $sections.Keys){$rows=@($sections[$sectionName]);$writer.WriteLine();$writer.WriteLine(('=== {0} ({1}) ===' -f $sectionName,$rows.Count));foreach($row in $rows){$pairs=@(foreach($prop in $row.PSObject.Properties){$val=ConvertTo-WsmConfirmationSafeText (ConvertTo-Json -InputObject $prop.Value -Depth 8 -Compress) 32768;('{0}: {1}' -f $prop.Name,$val)});$writer.WriteLine(($pairs -join ' | '))}}}finally{$writer.Dispose()}

        $allCsvRows=New-Object 'System.Collections.Generic.List[object]'
        foreach($sectionName in $sections.Keys){$rowIndex=0;foreach($row in @($sections[$sectionName])){$flat=[ordered]@{Section=$sectionName;RecordIndex=$rowIndex};foreach($prop in $row.PSObject.Properties){$flat[$prop.Name]=ConvertTo-WsmConfirmationSafeValue $prop.Value};$allCsvRows.Add([pscustomobject]$flat);$rowIndex++}}
        $headers=New-Object 'System.Collections.Generic.List[string]';foreach($common in @('Section','RecordIndex')){$headers.Add($common)};foreach($row in $allCsvRows){foreach($prop in $row.PSObject.Properties){if(-not $headers.Contains($prop.Name)){$headers.Add($prop.Name)}}}
        $writer=New-Object IO.StreamWriter($temporaries.Csv,$false,(New-Object Text.UTF8Encoding($false)))
        try{$writer.WriteLine((@($headers | ForEach-Object {ConvertTo-WsmConfirmationCsvField $_}) -join ','));foreach($row in $allCsvRows){$writer.WriteLine((@($headers | ForEach-Object {ConvertTo-WsmConfirmationCsvField (Get-WsmConfirmationValue $row $_ '')}) -join ','))}}finally{$writer.Dispose()}

        $htmlWriter=New-Object IO.StreamWriter($temporaries.Html,$false,(New-Object Text.UTF8Encoding($false)))
        try{$htmlWriter.WriteLine('<!doctype html><html lang="zh-Hant"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Windows Server environment confirmation</title><style>body{font:15px system-ui;margin:2rem;color:#182536}table{border-collapse:collapse;width:100%;margin:.5rem 0 2rem}td,th{border:1px solid #ccd;padding:.5rem;text-align:left;vertical-align:top;overflow-wrap:anywhere}th{background:#eaf0f7}.note{padding:1rem;background:#fff1cb}section{break-inside:auto}tr{break-inside:avoid}</style><h1>Windows Server 環境、軟體與相依確認</h1>');$htmlWriter.WriteLine(('<p class="note">DocumentId {0}; Pair {1}; inventory r{2}; decisions d{3}; target observation r{4}; projection {5}. 文件修改不會更新權威決策。ProductionQualified=false。</p>' -f [Net.WebUtility]::HtmlEncode($DocumentId),[Net.WebUtility]::HtmlEncode($Projection.PairId),$Projection.InventoryRevision,$Projection.DecisionRevision,$TargetRevision,[Net.WebUtility]::HtmlEncode($ProjectionHash)));$htmlWriter.WriteLine(('<p>Counts: {0}</p>' -f [Net.WebUtility]::HtmlEncode(($Projection.Counts | ConvertTo-Json -Compress))));foreach($sectionName in $sections.Keys){$rows=@($sections[$sectionName]);$htmlWriter.WriteLine(('<section><h2>{0} ({1})</h2>' -f [Net.WebUtility]::HtmlEncode($sectionName),$rows.Count));if($rows.Count){$columns=@($rows[0].PSObject.Properties.Name);$htmlWriter.WriteLine('<table><thead><tr>');foreach($column in $columns){$htmlWriter.WriteLine(('<th>{0}</th>' -f [Net.WebUtility]::HtmlEncode($column)))};$htmlWriter.WriteLine('</tr></thead><tbody>');foreach($row in $rows){$htmlWriter.WriteLine('<tr>');foreach($column in $columns){$value=Get-WsmConfirmationValue $row $column '';if($value -isnot [string]){$value=ConvertTo-Json -InputObject $value -Depth 10 -Compress};$htmlWriter.WriteLine(('<td>{0}</td>' -f [Net.WebUtility]::HtmlEncode((ConvertTo-WsmConfirmationSafeText $value 32768))))};$htmlWriter.WriteLine('</tr>')};$htmlWriter.WriteLine('</tbody></table>')}else{$htmlWriter.WriteLine('<p>0 rows; this does not establish readiness or global absence.</p>')};$htmlWriter.WriteLine('</section>')};$htmlWriter.WriteLine('<p>Owner handoff: confirm coverage, dependencies, target context, exact configuration, business tests, rollback, observation and retirement with their owners.</p></html>')}finally{$htmlWriter.Dispose()}

        foreach($key in $temporaries.Keys){$length=(Get-Item -LiteralPath $temporaries[$key]).Length;if($length -gt 128MB){throw ('Confirmation '+$key+' output exceeds the 128 MiB per-file metadata budget; no report was sealed.')}}
        foreach($key in $paths.Keys){[IO.File]::Move($temporaries[$key],$paths[$key])}
        $hashes=[ordered]@{};foreach($key in $paths.Keys){$hashes[$key]=(Get-FileHash -LiteralPath $paths[$key] -Algorithm SHA256).Hash.ToLowerInvariant()}
        [pscustomobject][ordered]@{Paths=[pscustomobject]$paths;Hashes=[pscustomobject]$hashes;Projection=$Projection;DocumentId=$DocumentId;TargetObservationRevision=$TargetRevision;ReportProjectionHash=$ProjectionHash;Counts=$Projection.Counts;AuthoritativeDecisionInput=$false;ProductionQualified=$false}
    } catch {
        foreach($temporary in $temporaries.Values){if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
        throw
    }
}

function Get-WsmEnvironmentConfirmationReferences {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId)
    Assert-WsmId $PairId
    $workspacePath=[IO.Path]::GetFullPath($Workspace);$indexPath=Join-Path (Join-Path $workspacePath 'environment-confirmations') ($PairId+'.json')
    if(-not [IO.File]::Exists($indexPath)){return [pscustomobject][ordered]@{PairId=$PairId;Documents=@();LatestDocumentId='';AuthoritativeApproval=$false;IndexPath=$indexPath}}
    Assert-WsmCancellationDirectoryProtection (Split-Path -Parent $indexPath)
    Assert-WsmNoReparse $indexPath
    $index=Read-WsmJson $indexPath
    if($index.Kind -cne 'EnvironmentConfirmationIndex' -or $index.PairId -cne $PairId -or $index.AuthoritativeApproval -ne $false){throw 'Environment confirmation locator index is invalid or incorrectly treated as approval.'}
    foreach($record in @($index.Documents)){
        if($record.PairId -cne $PairId -or $record.DocumentId -notmatch '^[0-9a-fA-F-]{36}$' -or $record.ReportProjectionHash -notmatch '^[a-f0-9]{64}$'){throw 'Environment confirmation locator record binding is invalid.'}
        $outputRoot=[IO.Path]::GetFullPath([string]$record.OutputRoot);Assert-WsmCancellationDirectoryProtection $outputRoot
        foreach($format in @('Markdown','Json','Html','Text','Csv')){if(-not $record.Paths.PSObject.Properties[$format] -or -not $record.Hashes.PSObject.Properties[$format] -or $record.Hashes.$format -notmatch '^[a-f0-9]{64}$'){throw 'Environment confirmation locator is missing an artifact binding.'};$path=[IO.Path]::GetFullPath([string]$record.Paths.$format);$prefix=$outputRoot.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar;if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Environment confirmation artifact escaped its controlled output root.'};Assert-WsmNoReparse $path;$file=Get-Item -LiteralPath $path -ErrorAction Stop;if($file.Length -gt 128MB -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $record.Hashes.$format){throw 'An immutable environment confirmation artifact is missing, oversized or changed.'}}
    }
    [pscustomobject][ordered]@{PairId=$PairId;Documents=@($index.Documents);LatestDocumentId=[string]$index.LatestDocumentId;IndexPath=$indexPath;IndexSHA256=(Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash.ToLowerInvariant();AuthoritativeApproval=$false;Status='Locator only; not approval or readiness evidence'}
}

function Export-WsmEnvironmentConfirmation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [ValidateSet('Review','Preparation','Staged','Final','Cutover','Acceptance','Retirement')][string]$Phase='Review',
        [string]$TargetObservationPath,
        [string]$TargetObservationHash,
        [string]$Context='',
        [object[]]$GeneralHostEvidence=@()
    )
    $catalog=Get-WsmCatalog $Workspace $PairId
    $observation=$null;$targetRevision=0
    if($TargetObservationPath -or $TargetObservationHash){
        if(-not $TargetObservationPath -or $TargetObservationHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'Target observation requires its path and independently trusted hash.'}
        $raw=Read-WsmTrustedJson $TargetObservationPath $TargetObservationHash
        Assert-WsmFields $raw @('SchemaVersion','ToolVersion','Kind','PairId','InventoryRevision','DecisionRevision','TargetObservationRevision','TargetFingerprint','ObservedUtc','Status') @('SchemaVersion','ToolVersion','Kind','PairId','InventoryRevision','DecisionRevision','TargetObservationRevision','TargetFingerprint','ObservedUtc','Status')
        Assert-WsmEnvelope $raw 'TargetObservation'
        if($raw.PairId -cne $PairId -or $raw.InventoryRevision -ne $catalog.InventoryRevision -or $raw.DecisionRevision -ne $catalog.DecisionRevision -or $raw.TargetObservationRevision -lt 1 -or $raw.TargetFingerprint -notmatch '^[a-f0-9]{64}$' -or $raw.Status -cnotin @('NotTested','Blocked','Observed')){throw 'Target observation is stale, mismatched or claims unsupported validation.'}
        $targetRevision=[long]$raw.TargetObservationRevision
        $observation=[pscustomobject][ordered]@{TargetObservationRevision=$targetRevision;TargetFingerprint=$raw.TargetFingerprint;ObservedUtc=$raw.ObservedUtc;Status=$raw.Status;SHA256=$TargetObservationHash.ToLowerInvariant();AuthoritativeReadinessProof=$false}
    }
    $projection=Get-WsmEnvironmentConfirmationProjection -Catalog $catalog -Phase $Phase -TargetObservation $observation -Context $Context -GeneralHostEvidence $GeneralHostEvidence
    $projectionJson=ConvertTo-Json -InputObject $projection -Depth 45 -Compress
    if([Text.Encoding]::UTF8.GetByteCount($projectionJson) -gt 128MB){throw 'Confirmation projection exceeds the 128 MiB bounded JSON budget; no document created.'}
    $projectionHash=Get-WsmHashText $projectionJson
    $documentId=[Guid]::NewGuid().ToString('D');$root=[IO.Path]::GetFullPath($OutputDirectory)
    foreach($item in $catalog.Items){$spec=Get-WsmConfirmationValue $item 'MigrationSpec' $null;foreach($key in @('SourcePath','TargetPath')){$scope=Get-WsmConfirmationValue $spec $key;if($scope -and (Test-WsmPathOverlap (Get-WsmPhysicalPath $scope) (Get-WsmPhysicalPath $root))){throw 'Confirmation output overlaps a migration scope.'}}}
    [void](New-WsmOutputOwnedDirectory $root)
    $stem='environment-software-'+$PairId+'-r'+$catalog.InventoryRevision+'-d'+$catalog.DecisionRevision+'-'+$documentId
    $written=Invoke-WsmLocked $root {Write-WsmEnvironmentConfirmationFiles $root $stem $projection $projectionHash $documentId $targetRevision}

    # The output lock has been released before the durable workspace locator is
    # appended, avoiding nested locks on the same workspace.
    $indexDirectory=Join-Path ([IO.Path]::GetFullPath($Workspace)) 'environment-confirmations'
    [void](New-WsmOutputOwnedDirectory $indexDirectory)
    Assert-WsmNoReparse $indexDirectory
    $indexPath=Join-Path $indexDirectory ($PairId+'.json')
    $locator=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='EnvironmentConfirmationIndex';PairId=$PairId;Documents=@();LatestDocumentId='';UpdatedUtc=Get-WsmUtc;AuthoritativeApproval=$false}
    $registered=Invoke-WsmLocked ([IO.Path]::GetFullPath($Workspace)) {
        Assert-WsmNoReparse $indexPath
        if([IO.File]::Exists($indexPath)){$current=Read-WsmJson $indexPath;if($current.Kind -cne 'EnvironmentConfirmationIndex' -or $current.PairId -cne $PairId -or $current.AuthoritativeApproval -ne $false){throw 'Existing environment confirmation index is invalid.'};$locator=$current}
        if(@($locator.Documents | Where-Object DocumentId -CEQ $documentId).Count){throw 'DocumentId already exists in the environment confirmation index.'}
        $record=[pscustomobject][ordered]@{DocumentId=$documentId;PairId=$PairId;InventoryRevision=$catalog.InventoryRevision;DecisionRevision=$catalog.DecisionRevision;TargetObservationRevision=$targetRevision;TargetObservationHash=[string](Get-WsmConfirmationValue $observation 'SHA256' '');TargetObservationStatus=[string](Get-WsmConfirmationValue $observation 'Status' 'NotTested');SourceInventoryProjectionHash=$projection.SourceInventoryProjectionHash;ReportProjectionHash=$projectionHash;GeneratedUtc=$projection.GeneratedUtc;OutputRoot=$root;Paths=$written.Paths;Hashes=$written.Hashes;Counts=$projection.Counts;AuthoritativeApproval=$false;ProductionQualified=$false}
        $locator.Documents=@($locator.Documents)+@($record);$locator.LatestDocumentId=$documentId;$locator.UpdatedUtc=Get-WsmUtc;Write-WsmJson $indexPath $locator
        $record
    }
    [pscustomobject][ordered]@{Path=$written.Paths.Markdown;JsonPath=$written.Paths.Json;HtmlPath=$written.Paths.Html;TextPath=$written.Paths.Text;CsvPath=$written.Paths.Csv;SHA256=$written.Hashes.Markdown;Hashes=$written.Hashes;IndexPath=$indexPath;IndexSHA256=(Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash.ToLowerInvariant();DocumentId=$documentId;TargetObservationRevision=$targetRevision;ReportProjectionHash=$projectionHash;Counts=$projection.Counts;AuthoritativeDecisionInput=$false;ProductionQualified=$false;Registered=$true;Reference=$registered}
}
