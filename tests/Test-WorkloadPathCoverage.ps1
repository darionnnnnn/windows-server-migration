#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
& $module {
    $script:checks=0
    function Check($Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
    $prior=[Environment]::GetEnvironmentVariable('WSM_REVIEW_ONLY_ROOT','Process')
    try {
        [Environment]::SetEnvironmentVariable('WSM_REVIEW_ONLY_ROOT','D:\ManagerOnly','Process')
        Check ((Get-WsmWorkloadPathChannel '%WSM_REVIEW_ONLY_ROOT%\app') -ceq 'Unknown') 'Manager environment was used as Source authority.'
        foreach($pair in @(@('C:\data','SuggestedC'),@('D:\data','SuggestedNonC'),@('E:\data','SuggestedNonC'),@('A:\data','SuggestedNonC'),@('\\server\share\data','Unknown'),@('relative\data','Unknown'))){Check ((Get-WsmWorkloadPathChannel $pair[0]) -ceq $pair[1]) ('Incorrect channel '+$pair[0])}
        $id=[Guid]::NewGuid().ToString()
        $site=New-WsmItem $id Web IISSite 'Site' 'Site' @{Xml='<site name="Site"><application path="/"><virtualDirectory path="/" physicalPath="%WSM_REVIEW_ONLY_ROOT%\site"/></application></site>'}
        $siteRefs=@(Get-WsmWorkloadPathReferences $site)
        Check ($siteRefs.Count -eq 1 -and $siteRefs[0].ReviewRequired -and $siteRefs[0].Opaque -and -not $siteRefs[0].ResolvedPath -and $siteRefs[0].Channel -ceq 'Unknown') 'Unresolved IIS environment root was marked resolved.'
        $task=New-WsmItem $id Tasks ScheduledTask 'Job' '\Job' @{TaskPath='\';TaskName='Job';Xml='<Task><Actions><ComHandler><ClassId>fixture</ClassId></ComHandler><Exec><Command>%WSM_REVIEW_ONLY_ROOT%\runner.exe</Command><Arguments>--input "D:\Data\input.csv" --output "E:\Results\output" --script "C:\Jobs\run.ps1" --remote "\\server\share\file.bin" --other relative.txt --token secret-canary</Arguments></Exec><Exec><Command>relative.exe</Command><WorkingDirectory>C:\Jobs\..\Other</WorkingDirectory></Exec></Actions></Task>'}
        $refs=@(Get-WsmWorkloadPathReferences $task)
        $command=@($refs|Where-Object {$_.ReferenceKind -ceq 'TaskCommand' -and $_.FieldPointer -match 'Action\[1\]'})
        Check ($command.Count -eq 1 -and $command[0].Opaque -and -not $command[0].ResolvedPath) 'Task principal environment must remain unresolved.'
        $candidates=@($refs|Where-Object ReferenceKind -CEQ 'TaskArgumentPath')
        Check ($candidates.Count -eq 4) 'Data, extensionless output, script and UNC candidates must all be visible.'
        Check (@($candidates|Where-Object {$_.Required -or -not $_.ReviewRequired}).Count -eq 0) 'Argument paths became automatic authorization.'
        Check (@($refs|Where-Object {$_.ReferenceKind -ceq 'TaskArguments' -and $_.Opaque -and $_.ReviewRequired}).Count -eq 1) 'Quoted candidates concealed unresolved argument semantics.'
        Check (@($refs|Where-Object {$_.ReferenceKind -ceq 'TaskWorkingDirectory' -and $_.FieldPointer -match 'Action\[1\]' -and $_.Opaque}).Count -eq 1) 'Missing working directory was silently omitted.'
        Check (@($refs|Where-Object {$_.FieldPointer -match 'Action\[2\]' -and $_.Opaque -and -not $_.ResolvedPath}).Count -eq 2) 'Relative or parent-segment paths were resolved on the reviewing host.'
        Check (($refs|ConvertTo-Json -Depth 20) -notmatch 'secret-canary|ManagerOnly') 'Safe projection leaked raw arguments or reviewer machine facts.'
        Check (@($refs|Where-Object {$_.ReferenceKind -ceq 'TaskAction' -and $_.FieldPointer -ceq 'Task/Actions/Action[0]'}).Count -eq 1) 'Unsupported action index was lost.'
        $inventory=New-WsmInventory ([pscustomobject]@{HostId=$id;Fingerprint=('a'*64);Name='Source';OS='fixture';Version='fixture'}) 1 @($site,$task)
        $discovery=Get-WsmWorkloadDiscovery $inventory
        Check (@($discovery.References|Where-Object {$_.ConsumerItemId -ceq $task.ItemId -and $_.ReferenceKind -ceq 'TaskArgumentPath'}).Count -eq 4) 'Public discovery consumer lost data candidates.'
        Check (@($discovery.References|Where-Object {$_.ConsumerItemId -ceq $site.ItemId -and $_.ReviewRequired}).Count -ge 1) 'Public discovery concealed the unresolved IIS root.'
        Write-Host ('PASS: '+$script:checks+' workload path coverage checks; unresolved Source context remains manual.')
    } finally {[Environment]::SetEnvironmentVariable('WSM_REVIEW_ONLY_ROOT',$prior,'Process')}
}
