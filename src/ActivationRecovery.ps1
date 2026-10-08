function Test-WsmActivationPhase($Item,$Ownership,[string]$Phase,$Package=$null,$State=$null) {
    $spec=$Item.MigrationSpec
    if($spec.Adapter -eq 'FileScope'){if(-not $Package){return $false};$map=Resolve-WsmIdentityMap $Package.Plan @{};$fileCheck=Test-WsmFileScope $Item $Package $spec.TargetPath $map;return ($fileCheck.Passed -and $fileCheck.ActualHash -ceq $Ownership.ActualHash)}
    if($spec.Adapter -eq 'ManualWorkflow'){if(-not $State){return $false};return (Test-WsmEvidence $State $Item.ItemId ManualRestore $State.ManifestHash)}
    $check=Test-WsmAdapterConfiguration $spec $Phase
    if(-not $check.Passed){return $false}
    if($spec.Adapter -eq 'WindowsFeature' -and $Ownership.CreatedByTool){try{[void](Test-WsmInstallerConsumers $spec.Desired $Ownership.InstallerSafety $Phase)}catch{return $false}}
    $true
}
function Assert-WsmActivationNetwork($Network) {
    if($env:COMPUTERNAME -ine $Network.FinalName){throw 'Final computer name drifted; activation resume cannot rename a live target.'}
    $addresses=@(Get-NetIPAddress -InterfaceAlias $Network.InterfaceAlias -IPAddress $Network.FinalIP -ErrorAction Stop)
    if($addresses.Count -ne 1 -or $addresses[0].PrefixLength -ne $Network.PrefixLength -or [string]$addresses[0].AddressState -ne 'Preferred'){throw 'Final IP/prefix is absent, duplicate, tentative or drifted.'}
    $dns=@((Get-DnsClientServerAddress -InterfaceAlias $Network.InterfaceAlias -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses)
    if(($dns -join ',') -cne (@($Network.DnsServers) -join ',')){throw 'Final DNS server order drifted.'}
    foreach($ip in $Network.TemporaryIP){if($ip -and $ip -ine $Network.FinalIP -and @(Get-NetIPAddress -InterfaceAlias $Network.InterfaceAlias -IPAddress $ip -ErrorAction SilentlyContinue).Count){throw 'Reviewed temporary IP remains; activation blocked.'}}
    if($Network.PSObject.Properties['DefaultGateway'] -and $Network.DefaultGateway){$routes=@(Get-NetRoute -InterfaceAlias $Network.InterfaceAlias -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop);if($routes.Count -ne 1 -or $routes[0].NextHop -cne $Network.DefaultGateway){throw 'Reviewed default gateway absent or ambiguous.'}}
}
function Invoke-WsmActivationSequence($Package,$Paths,$State,[switch]$Resume) {
    if(-not $State.Cutover.PSObject.Properties['Activations']){$State.Cutover | Add-Member NoteProperty Activations @()}
    foreach($item in (Get-WsmRestoreOrder @($Package.Plan.Items | Where-Object Decision -EQ Include))){
        $owned=@($State.Items | Where-Object ItemId -CEQ $item.ItemId);if($owned.Count -ne 1){throw 'Activation has no unique current restore ownership record.'}
        $specHash=Get-WsmHashText ($item.MigrationSpec | ConvertTo-Json -Depth 40 -Compress)
        $prior=@($State.Cutover.Activations | Where-Object ItemId -CEQ $item.ItemId)
        if($prior.Count -and -not $Resume){throw 'Existing activation checkpoint requires explicit activation resume.'}
        if($prior.Count -gt 1 -or ($prior.Count -and ($prior[0].SpecHash -cne $specHash -or $prior[0].ManifestHash -ine $State.ManifestHash))){throw 'Activation checkpoint binding mismatch.'}
        if($prior.Count -and $prior[0].Status -ceq 'Completed'){if(-not (Test-WsmActivationPhase $item $owned[0] Final $Package $State)){throw 'Previously activated item drifted; reconcile without replaying activation.'};continue}
        if($prior.Count -and (Test-WsmActivationPhase $item $owned[0] Final $Package $State)){
            $entry=$prior[0];$entry.Status='Completed';$entry.ObservedUtc=Get-WsmUtc
            Add-WsmJournal $Paths $State 'ActivationCompleted' $item.ItemId $entry;continue
        }
        if(-not (Test-WsmActivationPhase $item $owned[0] Staged $Package $State)){throw 'Interrupted activation is neither exact staged nor exact final state; reconcile the retained intent before resume.'}
        if(-not $prior.Count){
            $beforeHash='';if($item.MigrationSpec.Adapter -notin @('FileScope','ManualWorkflow')){$beforeHash=Get-WsmHashText ((Get-WsmAdapterState $item.MigrationSpec) | ConvertTo-Json -Depth 40 -Compress)}
            $entry=[pscustomobject]@{ItemId=$item.ItemId;SpecHash=$specHash;ManifestHash=$State.ManifestHash;Status='Intent';BeforeHash=$beforeHash;ObservedUtc='';Utc=(Get-WsmUtc)}
            $State.Cutover.Activations+=@($entry);Add-WsmJournal $Paths $State 'ActivationIntent' $item.ItemId $entry
        }else{$entry=$prior[0]}
        if($entry.BeforeHash -and $item.MigrationSpec.Adapter -notin @('FileScope','ManualWorkflow')){$observedHash=Get-WsmHashText ((Get-WsmAdapterState $item.MigrationSpec) | ConvertTo-Json -Depth 40 -Compress);if($observedHash -cne $entry.BeforeHash){throw 'Staged activation readback differs from the durable before-state; reconcile without replay.'}}
        # Intent is durable before the first native call. Never reset the transaction boundary on failure.
        Invoke-WsmAdapterActivation $item.MigrationSpec $true $owned[0]
        if(-not (Test-WsmActivationPhase $item $owned[0] Final $Package $State)){throw 'Activation returned without exact final configuration; retain intent and reconcile.'}
        $entry.Status='Completed';$entry.ObservedUtc=Get-WsmUtc;Add-WsmJournal $Paths $State 'ActivationCompleted' $item.ItemId $entry
    }
}
