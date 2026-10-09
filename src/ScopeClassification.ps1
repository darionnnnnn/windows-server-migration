function Get-WsmScopeField($Object,[string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) { if ([string]$key -ieq $Name) { return $Object[$key] } }
        return $null
    }
    $property=$Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    $null
}

function Get-WsmScopeClassification {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$Item)
    process {
        foreach ($field in @('ItemId','Category','Kind','Name','NaturalKey','Settings','Status')) {
            if (-not $Item.PSObject.Properties[$field]) { throw ('Scope classification requires item field: ' + $field) }
        }
        $category=[string]$Item.Category; $kind=[string]$Item.Kind
        $naturalKey=[string](Get-WsmScopeField $Item 'NaturalKey')
        $settings=Get-WsmScopeField $Item 'Settings'
        $name=[string](Get-WsmScopeField $Item 'Name')
        $displayName=[string](Get-WsmScopeField $settings 'DisplayName')
        $settingName=[string](Get-WsmScopeField $settings 'Name')
        $roleName=[string](Get-WsmScopeField $settings 'RoleName')
        $productName=[string](Get-WsmScopeField $settings 'ProductName')
        $text=($name+' '+$naturalKey+' '+$displayName+' '+$settingName+' '+$roleName+' '+$productName)
        $serviceIdentity=($naturalKey+' '+$settingName)
        $roleIdentity=($naturalKey+' '+$settingName+' '+$roleName)
        $productPattern='(?i)^(Oracle Database( Server)?\s+\d[\w.]*|Microsoft SQL Server\s+.+Database Engine Services|SQL Server (Database Engine|Reporting Services|Analysis Services)|PostgreSQL Server|MySQL Server|MariaDB Server|MongoDB Server)$'
        $disposition='Unknown'; $confidence='Low'; $rule='unknown.owner-review'; $reason='產品或探索結果無法可靠判定；需要 owner 覆核。'; $evidence=@('No specific classification rule matched.')
        if ($kind -in @('DiscoveryGap','CollectorFailure') -or [string]$Item.Status -cne 'Success') {
            $rule='unknown.incomplete-discovery'; $reason='探索項目未成功完成；不得將狀態解讀為不存在或可通過。'; $evidence=@('Collector status is incomplete.','Item kind indicates a discovery gap or collector failure.')
        }
        elseif (($category -ceq 'Services' -and $serviceIdentity -match '(?i)(^|[\\|\s])OracleService[A-Z0-9_$-]+($|[\\|\s])|(^|[\\|\s])OracleOraDB[0-9A-Za-z_]*TNSListener($|[\\|\s])|(^|[\\|\s])OracleTNSListener[A-Z0-9_]*($|[\\|\s])|(^|[\\|\s])MSSQLSERVER($|[\\|\s])|(^|[\\|\s])MSSQL\$[^\\|\s]+($|[\\|\s])|(^|[\\|\s])SQLSERVERAGENT($|[\\|\s])|(^|[\\|\s])postgresql-x64-\d+($|[\\|\s])|(^|[\\|\s])MySQL\d*($|[\\|\s])|(^|[\\|\s])MariaDB($|[\\|\s])|(^|[\\|\s])MongoDB($|[\\|\s])') -or
            ($category -ceq 'Roles' -and $roleIdentity -match '(?i)(^|\s)(AD-Domain-Services|ADCS-Cert-Authority|DNS|DHCP|Failover-Clustering|Hyper-V|FS-DFS-Replication|FS-DFS-Namespace|MSMQ|RDS-RD-Server|UpdateServices|Print-Services|NPAS|RemoteAccess)($|\s)') -or
            ($category -eq 'Runtime' -and ($displayName -match $productPattern -or $name -match $productPattern))) {
            $disposition='SpecialProduct'; $confidence='High'; $rule='special.server-product'; $reason='偵測到專用伺服器角色或資料庫引擎；需告知並由外部產品流程處理。'; $evidence=@('Service, role, or product metadata matched a known server-product rule.')
        }
        elseif ($text -match '(?i)Oracle (Client|Instant Client|Data Provider|ODAC)|ODP\.NET|Oracle\.DataAccess|Oracle\.ManagedDataAccess|oci\.dll|ODBC Driver|ODBC Data Source|OLE DB Provider|\.NET (Framework|Runtime|Hosting Bundle)|ASP\.NET Core Runtime|Visual C\+\+.*Redistributable|Java (Runtime|SE|JRE|JDK)|OpenJDK|Python(\s|$)|Node\.js|PHP(\s|$)|PowerShell (Module|Runtime)|URL Rewrite|Application Request Routing|\bARR\b|IIS.*(Module|Extension)|CrowdStrike|Falcon Sensor|SentinelOne|Microsoft Defender for Endpoint|Carbon Black|Sophos.*(Agent|Endpoint)|Tanium|Datadog Agent|New Relic.*Agent|Splunk Forwarder|Veeam Agent|Commvault.*Agent|Rubrik.*Agent|Zabbix Agent|PRTG.*(Probe|Agent)|N-able.*Agent|Ninja.*(Agent|RMM)') {
            $disposition='Preparation'; $confidence='High'; $rule='preparation.runtime-client-or-agent'; $reason='執行環境、client/provider、driver 或管理代理需在目標端依產品流程準備。'; $evidence=@('Product name or executable metadata matched a runtime, client/provider, driver, or redeployable-agent rule.')
        }
        elseif ($category -ceq 'System' -or $category -cin @('Network','Identity','Certificates') -or $kind -match '^(FirewallRule|IPConfiguration|Certificate|LocalUser|LocalGroup)$') {
            $disposition='SystemSetting'; $confidence='High'; $rule='system.setting-review'; $reason='Windows 系統或身分設定需逐項審核決策。'; $evidence=@('Item category or kind identifies a Windows system setting.')
        }
        elseif ($kind -match '^(IIS|IISSite|IISPool|IISGlobalConfig)$' -or $category -ceq 'Services' -or $kind -ceq 'ScheduledTask' -or $category -ceq 'Storage') {
            $disposition='GeneralMigration'; $confidence='Medium'; $rule='general.host-workload'; $reason='一般主機工作負載可留在遷移範圍；其相依仍需獨立確認。'; $evidence=@('Item kind identifies a service, scheduled task, IIS object, or non-clustered storage item.')
        }
        elseif ($category -ceq 'Roles') {
            $disposition='Preparation'; $confidence='Medium'; $rule='preparation.windows-role'; $reason='Windows 角色或功能需由使用者在目標主機準備及驗證。'; $evidence=@('Installed role metadata did not match a known special-product rule.')
        }
        elseif ($category -ceq 'Runtime') {
            $disposition='Unknown'; $confidence='Low'; $rule='unknown.product-role'; $reason='角色或已安裝產品缺少足夠資訊；需要 owner 覆核。'; $evidence=@('Product or role metadata did not match a supported preparation or special-product rule.')
        }
        $result=[pscustomobject][ordered]@{
            SchemaVersion=1
            ClassifierVersion='1.0.0'
            Disposition=$disposition
            Reason=$reason
            Evidence=@($evidence)
            Confidence=$confidence
            RuleId=$rule
        }
        $result
    }
}

function Assert-WsmScopeClassification {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$Item)
    process {
        if ($Item.PSObject.Properties['Classification']) {
            $attached=$Item.Classification
            $fields=@('SchemaVersion','ClassifierVersion','Disposition','Reason','Evidence','Confidence','RuleId')
            foreach ($field in $fields) {
                if (-not $attached -or -not $attached.PSObject.Properties[$field]) { throw 'Invalid attached scope classification: required field is missing.' }
            }
            $propertyCount=@($attached.PSObject.Properties).Count
            if ($propertyCount -ne $fields.Count -or ($attached.SchemaVersion -isnot [int] -and $attached.SchemaVersion -isnot [long]) -or $attached.SchemaVersion -ne 1 -or $attached.ClassifierVersion -cne '1.0.0' -or @('GeneralMigration','Preparation','SystemSetting','SpecialProduct','Unknown') -cnotcontains $attached.Disposition -or @('High','Medium','Low') -cnotcontains $attached.Confidence -or -not $attached.Reason -or -not $attached.RuleId -or $attached.Evidence -isnot [array] -or $attached.Evidence.Count -lt 1) { throw 'Invalid attached scope classification: field value is invalid.' }
            foreach ($evidence in $attached.Evidence) { if ($evidence -isnot [string] -or [string]::IsNullOrWhiteSpace($evidence)) { throw 'Invalid attached scope classification evidence.' } }
            $expected=Get-WsmScopeClassification $Item
            if ($attached.SchemaVersion -ne $expected.SchemaVersion -or $attached.ClassifierVersion -cne $expected.ClassifierVersion -or $attached.Disposition -cne $expected.Disposition -or $attached.Reason -cne $expected.Reason -or $attached.Confidence -cne $expected.Confidence -or $attached.RuleId -cne $expected.RuleId -or $attached.Evidence.Count -ne $expected.Evidence.Count) { throw 'Attached scope classification does not match the current classifier projection.' }
            for ($index=0; $index -lt $expected.Evidence.Count; $index++) { if ($attached.Evidence[$index] -cne $expected.Evidence[$index]) { throw 'Attached scope classification does not match the current classifier projection.' } }
        }
        $true
    }
}

function Get-WsmGeneralHostAssessment {
    [CmdletBinding(DefaultParameterSetName='Inventory')]
    param(
        [Parameter(Mandatory, ParameterSetName='Inventory')][object]$Inventory,
        [Parameter(Mandatory, ParameterSetName='Catalog')][object]$Catalog
    )
    $data=$Inventory
    if ($PSCmdlet.ParameterSetName -eq 'Catalog') { $data=$Catalog }
    if ($PSCmdlet.ParameterSetName -eq 'Inventory' -and $data.Kind -ceq 'Inventory') { Assert-WsmInventory $data }
    elseif ($PSCmdlet.ParameterSetName -eq 'Catalog' -and $data.Kind -ceq 'Catalog') {
        Assert-WsmEnvelope $data 'Catalog'
        Assert-WsmId $data.PairId
        if (-not $data.Source) { throw 'Invalid catalog source binding.' }
        Assert-WsmId $data.Source.HostId
        if ($data.Source.Fingerprint -notmatch '^[a-f0-9]{64}$') { throw 'Invalid catalog source binding.' }
        $catalogIds=@{}
        foreach ($item in @($data.Items)) {
            foreach ($field in @('ItemId','Category','Kind','Name','NaturalKey','Settings','SettingsHash','Dependencies','Status','Adapter')) { if (-not $item.PSObject.Properties[$field]) { throw ('Invalid catalog item: missing ' + $field) } }
            if ($script:Categories -cnotcontains $item.Category -or $item.ItemId -notmatch '^[a-f0-9]{64}$' -or $catalogIds.ContainsKey($item.ItemId)) { throw 'Invalid catalog item identity or category.' }
            $catalogIds[$item.ItemId]=$true
            $expectedId=Get-WsmHashText ($data.Source.HostId+'|'+$item.Category+'|'+$item.Kind+'|'+$item.NaturalKey.ToLowerInvariant())
            if ($expectedId -cne $item.ItemId -or $item.SettingsHash -cne (Get-WsmHashText ($item.Settings | ConvertTo-Json -Depth 30 -Compress))) { throw 'Invalid catalog item identity or settings hash.' }
            if (@('Success','Partial','NotInstalled','PermissionDenied','Unsupported','Failed') -cnotcontains $item.Status) { throw 'Invalid catalog collector status.' }
            foreach ($dependency in @($item.Dependencies)) { if ($dependency.ItemId -notmatch '^[a-f0-9]{64}$' -or @('Mandatory','Optional','External') -cnotcontains $dependency.Type) { throw 'Invalid catalog dependency.' } }
        }
    } else { throw 'Assessment input must be a valid Inventory or Catalog.' }
    $items=@($data.Items)
    $rows=New-Object System.Collections.Generic.List[object]; $gaps=New-Object System.Collections.Generic.List[object]
    $counts=[ordered]@{GeneralMigration=0;Preparation=0;SystemSetting=0;SpecialProduct=0;Unknown=0}; $categoryCounts=[ordered]@{}
    foreach ($category in $script:Categories) { $categoryCounts[$category]=0 }
    $ids=@{}; foreach ($item in $items) { if ($item.ItemId) { $ids[$item.ItemId]=$true } }
    $relations=New-Object System.Collections.Generic.List[object]
    foreach ($item in $items) {
        if (-not $item.PSObject.Properties['ItemId'] -or -not $item.PSObject.Properties['Dependencies']) { throw 'Assessment item is missing identity or dependencies.' }
        [void](Assert-WsmScopeClassification $item)
        $classification=Get-WsmScopeClassification $item
        $counts[$classification.Disposition]++
        if (-not $categoryCounts.Contains([string]$item.Category)) { throw 'Assessment item has an unknown category.' }; $categoryCounts[[string]$item.Category]++
        $row=[pscustomobject][ordered]@{ ItemId=[string]$item.ItemId; Category=[string]$item.Category; Kind=[string]$item.Kind; Name=[string]$item.Name; Status=[string]$item.Status; Classification=$classification }
        $rows.Add($row)
        if ($classification.Disposition -ceq 'Unknown' -or $item.Kind -in @('DiscoveryGap','CollectorFailure') -or $item.Status -cne 'Success') { $gaps.Add([pscustomobject]@{ItemId=[string]$item.ItemId;Kind=[string]$item.Kind;Status=[string]$item.Status;Reason=$classification.Reason;Confidence=$classification.Confidence}) }
        foreach ($dependency in @($item.Dependencies)) {
            $target=[string]$dependency.ItemId
            $resolved=$ids.ContainsKey($target)
            $relations.Add([pscustomobject]@{FromItemId=[string]$item.ItemId;ToItemId=$target;Type=[string]$dependency.Type;Resolved=$resolved})
            if (-not $resolved) { $gaps.Add([pscustomobject]@{ItemId=[string]$item.ItemId;Kind='UnresolvedDependency';Status='ReviewRequired';TargetItemId=$target;Reason='Dependency target is absent from this inventory or catalog.';Confidence='High'}) }
        }
    }
    [pscustomobject][ordered]@{
        SchemaVersion=1; ClassifierVersion='1.0.0'; SourceHostId=[string]$data.Source.HostId; SourceFingerprint=[string]$data.Source.Fingerprint
        InventoryRevision=if($data.PSObject.Properties['Revision']){$data.Revision}else{$data.InventoryRevision}
        TotalItems=$items.Count; CountsByDisposition=$counts; CountsByCategory=$categoryCounts
        Items=@($rows.ToArray()); Gaps=@($gaps.ToArray()); Relations=@($relations.ToArray())
    }
}
