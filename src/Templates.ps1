function Export-WsmReviewTemplate {
    param([string]$Workspace,[string]$PairId,[string]$RuleId,[string]$Path)
    $c=Get-WsmCatalog $Workspace $PairId
    $matches=@($c.History | Where-Object { $_.PSObject.Properties['Rule'] -and $_.Rule.RuleId -ceq $RuleId })
    if ($matches.Count -ne 1) { throw (New-WsmContractError 'Rule history not found or ambiguous.') }
    $rule=$matches[0].Rule | Select-Object Category,Search,CurrentDecision,BuiltIn,ApplicationGroup,Decision,Reason
    $template=[pscustomobject]@{ SchemaVersion=1; ToolVersion=$script:ToolVersion; Kind='ReviewTemplate'; Rule=$rule }
    Write-WsmJson $Path $template
    [pscustomobject]@{ Path=[IO.Path]::GetFullPath($Path); SHA256=(Get-FileHash -LiteralPath $Path).Hash }
}
function Read-WsmReviewTemplate([string]$Path,[string]$ExpectedHash) {
    $t=Read-WsmTrustedJson $Path $ExpectedHash; Assert-WsmEnvelope $t 'ReviewTemplate'
    if ((@($t.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'Kind,Rule,SchemaVersion,ToolVersion' -or (@($t.Rule.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'ApplicationGroup,BuiltIn,Category,CurrentDecision,Decision,Reason,Search') { throw (New-WsmContractError 'Template contains unknown fields; identities, secrets and target state cannot be copied.') }
    $r=$t.Rule
    if (($r.Category -and $script:Categories -cnotcontains $r.Category) -or @('All','Include','Exclude','Pending') -cnotcontains $r.CurrentDecision -or @('Unknown','All','SuggestedInternal','ConfirmedInternal','ConfirmedThirdParty') -cnotcontains $r.BuiltIn -or @('Include','Exclude','Pending') -cnotcontains $r.Decision) { throw (New-WsmContractError 'Invalid template filter or decision.') }
    foreach ($value in @($r.Search,$r.ApplicationGroup,$r.Reason)) { if ($value -isnot [string] -or $value.Length -gt 4096) { throw (New-WsmContractError 'Template text must be a bounded literal string.') } }
    if ($r.Decision -eq 'Exclude' -and [string]::IsNullOrWhiteSpace($r.Reason)) { throw (New-WsmContractError 'Template exclusion requires a reason.') }
    $r
}
function Get-WsmTemplatePreview {
    param([string]$Workspace,[string]$PairId,[string]$Path,[string]$ExpectedHash)
    $r=Read-WsmReviewTemplate $Path $ExpectedHash
    Get-WsmRulePreview $Workspace $PairId -Category $r.Category -Search $r.Search -CurrentDecision $r.CurrentDecision -BuiltIn $r.BuiltIn -Group $r.ApplicationGroup -Decision $r.Decision -Reason $r.Reason
}
function Invoke-WsmReviewTemplate {
    [CmdletBinding(SupportsShouldProcess)] param([string]$Workspace,[string]$PairId,[string]$Path,[string]$ExpectedHash,[int]$ExpectedRevision)
    $r=Read-WsmReviewTemplate $Path $ExpectedHash
    if ($PSCmdlet.ShouldProcess($PairId,'Apply reviewed matching conditions; generate destination-specific ItemIds')) {
        Invoke-WsmReviewRule $Workspace $PairId -Category $r.Category -Search $r.Search -CurrentDecision $r.CurrentDecision -BuiltIn $r.BuiltIn -Group $r.ApplicationGroup -Decision $r.Decision -Reason $r.Reason -ExpectedRevision $ExpectedRevision
    }
}
