#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../src/WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-er-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try {
 & $module {
  param($root)
  $script:exactReviewChecks=0
  function Check([bool]$ok,[string]$message){if(-not $ok){throw $message};$script:exactReviewChecks++}
  function Reject($action,[string]$message){$failed=$false;try{& $action|Out-Null}catch{$failed=$true};Check $failed $message}
  $workspace=Join-Path $root 'manager';Initialize-WsmWizardWorkspace $workspace Manager|Out-Null
  $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString('D');Fingerprint=('a'*64);Name='Exact review fixture'}
  $item=New-WsmItem $source.HostId Storage PathCandidate 'Explicit business files' 'C:\business-data' ([pscustomobject]@{OriginalPath='C:\business-data';ResolvedCandidate='C:\business-data'})
  $inventory=New-WsmInventory $source 1 @($item);$inventoryPath=Join-Path $root 'inventory.json';Write-WsmJson $inventoryPath $inventory
  $catalog=Import-WsmInventory $workspace $inventoryPath (Get-FileHash $inventoryPath).Hash 'Review target'
  $catalog=Enable-WsmAssistiveMode $workspace $catalog.PairId $catalog.DecisionRevision
  $members=@(1..2001|ForEach-Object {[pscustomobject]@{RelativePath=('business-'+$_.ToString('D4')+'.dat');SHA256=('b'*64)}})
  $spec=[pscustomobject]@{Adapter='FileScope';SourcePath='C:\business-data';TargetPath='C:\business-data';TransferChannel='C';ContentSelection='ExactMembers';Members=$members;ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';ConflictPolicy='Block';Owner='Fixture owner';Evidence='Explicit member fixture; no content capture claim'}
  $specPath=Join-Path $root 'spec.json';Write-WsmJson $specPath $spec
  Set-WsmMigrationSpec $workspace $catalog.PairId $item.ItemId $specPath (Get-FileHash $specPath).Hash $catalog.DecisionRevision
  $review=Get-WsmAssistiveSpecReview $workspace $catalog.PairId $item.ItemId
  $expected=Get-WsmHashText (ConvertTo-Json -InputObject $members -Depth 8 -Compress)
  Check ($review.TypedFields.ExactMemberSummary.Count -eq 2001 -and $review.TypedFields.ExactMemberSummary.SetHash -ceq $expected) 'Summary must represent every confirmed member, including the last row.'
  Check (-not $review.TypedFields.PSObject.Properties['Members']) 'Exact files must not become the LocalGroup Members editor.'
  $form=Get-WsmWizardPreparationReview $workspace $catalog.PairId $item.ItemId
  $selection=@($form.FormFields|Where-Object key -CEQ 'ContentSelection')
  Check ($selection.Count -eq 1 -and -not $selection[0].editable -and $selection[0].value -ceq 'ExactMembers') 'Exact selection can be widened by the wizard.'
  $summary=@($form.FormFields|Where-Object {$_.key -like 'ExactMemberSummary/*'})
  Check ($summary.Count -eq 3 -and @($summary|Where-Object editable).Count -eq 0 -and $form.FormFields.Count -lt 512) 'Large exact set must expose a bounded read-only summary.'
  Reject {Save-WsmWizardPreparationReview $workspace $catalog.PairId $item.ItemId $form.ReviewHash 'Owner' 'Review' @{ContentSelection='WholeScope'}} 'Wizard allowed widening to a directory.'
  Reject {Save-WsmWizardPreparationReview $workspace $catalog.PairId $item.ItemId $form.ReviewHash 'Owner' 'Review' @{'ExactMemberSummary/Count'=1}} 'Wizard accepted a forged summary.'
  Reject {Submit-WsmAssistiveSpecReview $workspace $catalog.PairId $item.ItemId $review.DecisionRevision $review.AssistiveRevision $review.SelectionRevision 'Owner' 'Review' @{TargetPath='C:\business-data';ContentSelection='WholeScope'}} 'Direct typed review widened an exact set.'
  Reject {Submit-WsmAssistiveSpecReview $workspace $catalog.PairId $item.ItemId $review.DecisionRevision $review.AssistiveRevision $review.SelectionRevision 'Owner' 'Review' @{TargetPath='C:\business-data';Members=@()}} 'Direct typed review changed member identity.'
  $saved=Save-WsmWizardPreparationReview $workspace $catalog.PairId $item.ItemId $form.ReviewHash 'Reviewed owner' 'Confirmed exact original selection' @{}
  $after=Get-WsmCatalog $workspace $catalog.PairId;$savedSpec=@($after.Items|Where-Object ItemId -CEQ $item.ItemId)[0].MigrationSpec
  Check ($savedSpec.ContentSelection -ceq 'ExactMembers' -and (Get-WsmHashText (ConvertTo-Json -InputObject @($savedSpec.Members) -Depth 8 -Compress)) -ceq $expected -and $savedSpec.Members[-1].RelativePath -ceq 'business-2001.dat') 'Save lost or expanded immutable member bytes.'
  Check ($savedSpec.Owner -ceq 'Reviewed owner' -and [IO.File]::Exists($saved.SpecPath) -and -not $after.Approval) 'Normal owner review did not persist through the formal spec artifact.'
  Reject {Save-WsmWizardPreparationReview $workspace $catalog.PairId $item.ItemId $form.ReviewHash 'Owner' 'Old review' @{}} 'Stale exact-set form was accepted.'
  $reopened=Get-WsmWizardPreparationReview $workspace $catalog.PairId $item.ItemId
  Check ($reopened.ReviewHash -cne $form.ReviewHash -and @($reopened.FormFields|Where-Object {$_.key -ceq 'ExactMemberSummary/SetHash' -and $_.value -ceq $expected}).Count -eq 1) 'Reopened review lost exact-set binding.'
  $groupFields=Get-WsmWizardPreparationFields ([pscustomobject]@{Adapter='LocalGroup';TypedFields=[pscustomobject]@{Desired=[pscustomobject]@{Name='fixture';Members=@('one','two')}};SharedResourceReviewReasons=@()})
  $groupForm=@(Get-WsmWizardPreparationForm $groupFields 'LocalGroup')
  Check (@($groupForm|Where-Object {$_.key -ceq 'Desired/Members' -and $_.editable}).Count -eq 1) 'File review restriction broke LocalGroup member editing.'
  Write-Host ('PASS: '+$script:exactReviewChecks+' exact-member review checks; formal save/reopen, bounded 2001-member summary, immutable identity, stale review and LocalGroup isolation.')
 } $root
} finally {if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force}}
