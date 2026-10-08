function Assert-WsmDependencyReceipts($Plan,[object[]]$Receipts) {
    $required=@();if($Plan.PSObject.Properties['CrossHostDependencies']){$required=@($Plan.CrossHostDependencies | Where-Object Type -EQ Mandatory)}
    $seen=@{};foreach($receipt in $Receipts){Assert-WsmFields $receipt @('Result','IndependentHash') @('Result','IndependentHash');$r=$receipt.Result;Assert-WsmEnvelope $r 'StageResult';Assert-WsmId $r.PairId
        if($seen.ContainsKey($r.PairId) -or $receipt.IndependentHash -notmatch '^[a-fA-F0-9]{64}$' -or $r.Stage -cne 'Cutover' -or $r.Status -cne 'Succeeded' -or $r.Mode -cne 'IsolatedPilot' -or $r.ProductionVerified -ne $false -or $r.ManifestHash -notmatch '^[a-fA-F0-9]{64}$' -or $r.PayloadGeneration -lt 1){throw 'Dependency result is incomplete, duplicate or not activated.'}
        $utc=[DateTimeOffset]::MinValue;if(-not [DateTimeOffset]::TryParse($r.ProducedUtc,[ref]$utc) -or $utc.Offset -ne [TimeSpan]::Zero -or $utc -gt [DateTimeOffset]::UtcNow.AddMinutes(5) -or $utc -lt [DateTimeOffset]::UtcNow.AddHours(-24)){throw 'Dependency result expired or clock invalid; refresh its target result.'};$seen[$r.PairId]=$true
    }
    foreach($edge in $required){if(-not $seen.ContainsKey($edge.PairId)){throw ('Mandatory cross-host provider has not supplied a fresh activated result: '+$edge.PairId)}}
}
function Read-WsmDependencyReceipts($Plan,[string]$Path,[string]$Hash) {
    $receipts=@();if($Path){$input=Read-WsmTrustedJson $Path $Hash;Assert-WsmFields $input @('Entries') @('Entries');foreach($entry in $input.Entries){Assert-WsmFields $entry @('Path','SHA256') @('Path','SHA256');$receipts+=@([pscustomobject]@{Result=(Read-WsmTrustedJson $entry.Path $entry.SHA256);IndependentHash=$entry.SHA256})}}
    Assert-WsmDependencyReceipts $Plan $receipts;return ,$receipts
}
