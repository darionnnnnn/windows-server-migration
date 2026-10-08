@{
    RootModule = 'WindowsServerMigration.psm1'
    ModuleVersion = '0.2.0'
    GUID = 'f9a991e9-4a49-44d4-8633-e15e844ddc3b'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Initialize-WsmWorkspace','Get-WsmFleet','Get-WsmCatalog','New-WsmItem','New-WsmInventory','Import-WsmInventory','Import-WsmInventoryArchive','Get-WsmItems','Set-WsmDecision','Undo-WsmDecision','Export-WsmDecisions','Import-WsmDecisions','Get-WsmReviewIssues','Set-WsmMapping','Set-WsmEvidence','Export-WsmReport','Export-WsmTextReport','Export-WsmFleetReport','Approve-WsmPlan','Import-WsmApprovedPlan','Export-WsmInventory','Get-WsmPreflight','Get-WsmCapabilities','Export-WsmReviewTemplate','Get-WsmTemplatePreview','Invoke-WsmReviewTemplate','Set-WsmConsistencyGroup','Get-WsmCategorySummary','Get-WsmDecisionPreview','Get-WsmRulePreview','Invoke-WsmReviewRule','Add-WsmManualItem','Set-WsmReviewMetadata','Set-WsmDependencies','Set-WsmReviewView','Set-WsmPairPlan','Set-WsmCrossHostDependency','Export-WsmFleetGraph','Import-WsmStageResult')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
