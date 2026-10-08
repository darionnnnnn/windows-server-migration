@{
    RootModule = 'WindowsServerMigration.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'f9a991e9-4a49-44d4-8633-e15e844ddc3b'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Initialize-WsmWorkspace','Get-WsmFleet','Get-WsmCatalog','New-WsmItem','New-WsmInventory','Import-WsmInventory','Get-WsmItems','Set-WsmDecision','Undo-WsmDecision','Export-WsmDecisions','Import-WsmDecisions','Get-WsmReviewIssues','Set-WsmMapping','Set-WsmEvidence','Export-WsmReport','Export-WsmFleetReport','Approve-WsmPlan','Import-WsmApprovedPlan','Export-WsmInventory','Get-WsmPreflight')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
