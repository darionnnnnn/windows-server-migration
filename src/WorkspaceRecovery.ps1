function Complete-WsmWorkspaceTransaction([string]$Workspace) {
    $intentPath=Join-Path $Workspace 'workspace-transaction.json';if(-not [IO.File]::Exists($intentPath)){return}
    $intent=Read-WsmJson $intentPath;Assert-WsmEnvelope $intent 'WorkspaceTransaction';Assert-WsmId $intent.TransactionId;Assert-WsmId $intent.PairId
    $folder=Join-Path (Join-Path $Workspace 'transactions') $intent.TransactionId;Assert-WsmNoReparse $folder
    foreach($entry in $intent.Entries){if($entry.Name -notin @('catalog.json','fleet.json') -or $entry.NewHash -notmatch '^[a-f0-9]{64}$'){throw 'Invalid workspace transaction entry.'};$path=Join-Path $Workspace 'fleet.json';if($entry.Name -eq 'catalog.json'){$path=Get-WsmCatalogPath $Workspace $intent.PairId};$current='';if([IO.File]::Exists($path)){$current=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()};if($current -cne $entry.OldHash -and $current -cne $entry.NewHash){throw 'Workspace changed outside interrupted transaction; retain evidence.'};$source=Join-Path $folder $entry.Name;[void](Read-WsmTrustedJson $source $entry.NewHash)}
    foreach($entry in $intent.Entries){$path=Join-Path $Workspace 'fleet.json';if($entry.Name -eq 'catalog.json'){$path=Get-WsmCatalogPath $Workspace $intent.PairId};$current='';if([IO.File]::Exists($path)){$current=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()};if($current -cne $entry.NewHash){$data=Read-WsmTrustedJson (Join-Path $folder $entry.Name) $entry.NewHash;Write-WsmJson $path $data;if((Get-FileHash -LiteralPath $path).Hash -ine $entry.NewHash){throw 'Transaction destination differs from staged content.'}}}
    [IO.File]::Delete($intentPath)
}
function Write-WsmWorkspaceTransaction([string]$Workspace,$Catalog,$Fleet) {
    if([IO.File]::Exists((Join-Path $Workspace 'workspace-transaction.json'))){throw 'Repair pending workspace transaction first.'}
    $id=[Guid]::NewGuid().ToString();$folder=Join-Path (Join-Path $Workspace 'transactions') $id;[void][IO.Directory]::CreateDirectory($folder);Protect-WsmDirectory $folder;$entries=@()
    foreach($name in @('catalog.json','fleet.json')){$destination=Join-Path $Workspace 'fleet.json';$data=$Fleet;if($name -eq 'catalog.json'){$destination=Get-WsmCatalogPath $Workspace $Catalog.PairId;$data=$Catalog};$old='';if([IO.File]::Exists($destination)){$old=(Get-FileHash -LiteralPath $destination).Hash.ToLowerInvariant()};$staged=Join-Path $folder $name;Write-WsmJson $staged $data;$entries+=@([pscustomobject]@{Name=$name;OldHash=$old;NewHash=(Get-FileHash -LiteralPath $staged).Hash.ToLowerInvariant()})}
    Write-WsmJson (Join-Path $Workspace 'workspace-transaction.json') ([pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='WorkspaceTransaction';TransactionId=$id;PairId=$Catalog.PairId;Entries=$entries;CreatedUtc=(Get-WsmUtc)})
    Complete-WsmWorkspaceTransaction $Workspace
}
function Repair-WsmWorkspace {
    [CmdletBinding(SupportsShouldProcess)]param([string]$Workspace)
    Invoke-WsmLocked $Workspace {if($PSCmdlet.ShouldProcess($Workspace,'Complete hash-verified interrupted inventory/fleet transaction')){Complete-WsmWorkspaceTransaction $Workspace};[pscustomobject]@{RecoveryRequired=[IO.File]::Exists((Join-Path $Workspace 'workspace-transaction.json'));RetainedTransactions=(Join-Path $Workspace 'transactions')}}
}
