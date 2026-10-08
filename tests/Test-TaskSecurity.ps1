#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
& $module {
    . (Join-Path $PSScriptRoot '..\src\TaskSecurity.ps1')
    $script:folderSddl=@{};$script:folderObjects=@{};$script:taskSddl='O:SYG:SYD:(A;;FA;;;SY)(A;;FR;;;BA)';$script:events=@();$script:descriptorFlags=@();$script:missingHResult=-2147024893;$script:denyPath='';$script:tamperCreated=$false
    $script:rootSddl='O:SYG:SYD:(A;;FA;;;SY)';$script:opsSddl='O:SYG:SYD:(A;;FA;;;SY)(A;;FA;;;BA)';$script:dailySddl='O:BAG:BAD:P(A;;FA;;;BA)(A;;FA;;;SY)'
    function New-FixtureFolder([string]$Path){
        if($script:folderObjects.ContainsKey($Path)){return $script:folderObjects[$Path]}
        $folder=[pscustomobject]@{Path=$Path}
        $folder | Add-Member ScriptMethod GetSecurityDescriptor {param($Flags)if($Flags -ne 7){throw 'Expected owner/group/DACL security read.'};$script:descriptorFlags+=@($Flags);$script:folderSddl[$this.Path]}
        $folder | Add-Member ScriptMethod GetFolder {param($Name)if($script:denyPath -ceq ($this.Path+$Name+'\')){throw (New-Object System.Runtime.InteropServices.COMException('fixture access denied',-2147024891))};$path=$this.Path+$Name+'\';if(-not $script:folderSddl.ContainsKey($path)){throw (New-Object System.Runtime.InteropServices.COMException('fixture folder missing',$script:missingHResult))};New-FixtureFolder $path}
        $folder | Add-Member ScriptMethod CreateFolder {param($Name,$Sddl)$path=$this.Path+$Name+'\';if($script:folderSddl.ContainsKey($path)){throw (New-Object System.Runtime.InteropServices.COMException('fixture folder already exists',-2147024713))};$script:events+=@('Create:'+ $path);$script:folderSddl[$path]=$Sddl;if($script:tamperCreated){$script:folderSddl[$path]=$script:opsSddl;$script:tamperCreated=$false};New-FixtureFolder $path}
        $folder | Add-Member ScriptMethod GetTask {param($Name)if($this.Path -cne '\Ops\Daily\' -or $Name -cne 'FixtureTask'){throw 'Unexpected task identity'};$task=[pscustomobject]@{Name=$Name};$task | Add-Member ScriptMethod GetSecurityDescriptor {param($Flags)if($Flags -ne 7){throw 'Expected task owner/group/DACL security read.'};$script:descriptorFlags+=@($Flags);$script:taskSddl};$task}
        $script:folderObjects[$Path]=$folder;$folder
    }
    $script:folderSddl['\']=$script:rootSddl;$script:folderSddl['\Ops\']=$script:opsSddl;$script:folderSddl['\Ops\Daily\']=$script:dailySddl
    $rootFolder=New-FixtureFolder '\';$scheduler=[pscustomobject]@{};$scheduler | Add-Member ScriptMethod GetFolder {param($Path)if(-not $script:folderSddl.ContainsKey($Path)){throw (New-Object System.Runtime.InteropServices.COMException('fixture folder missing',$script:missingHResult))};New-FixtureFolder $Path};$script:fixtureScheduler=$scheduler
    function script:New-WsmTaskScheduler {$script:fixtureScheduler}
    function Assert-TaskSecurityThrows([scriptblock]$Action,[string]$Label){$failed=$false;try{& $Action | Out-Null}catch{$failed=$true};if(-not $failed){throw ('Expected Task Security rejection: '+$Label)}}
    function Reset-TaskSecurityFixture([bool]$IncludeDaily=$true){$script:folderSddl=@{'\'=$script:rootSddl;'\Ops\'=$script:opsSddl};if($IncludeDaily){$script:folderSddl['\Ops\Daily\']=$script:dailySddl};$script:folderObjects=@{};$script:events=@();$script:descriptorFlags=@();$script:denyPath='';$script:tamperCreated=$false;New-FixtureFolder '\' | Out-Null}
    function New-TaskFolderSpec([string]$Path,[string]$Sddl,[string]$Policy){[pscustomobject][ordered]@{Path=$Path;SecuritySddl=$Sddl;ExistingPolicy=$Policy}}

    # Source capture binds the task plus every folder ancestor, including Scheduler root, with the exact owner/group/DACL query flags.
    Reset-TaskSecurityFixture
    $capture=Capture-WsmTaskSecurity '\Ops\Daily\' 'FixtureTask' $script:fixtureScheduler
    if($capture.Kind -cne 'TaskSecurityCapture' -or $capture.TaskFullPath -cne '\Ops\Daily\FixtureTask' -or $capture.TaskSecuritySddl -cne $script:taskSddl -or $capture.Folders.Count -ne 3 -or (($capture.Folders.Path -join '|') -cne '\|\Ops\|\Ops\Daily\') -or @($script:descriptorFlags | Where-Object {$_ -ne 7}).Count){throw 'Source task/folder security capture omitted exact task identity, ancestor ACLs or descriptor sections.'}
    foreach($row in $capture.Folders){if($row.SecurityHash -cne (Get-WsmHashText $row.SecuritySddl)){throw ('Source folder ACL hash mismatch: '+$row.Path)}}

    # Existing parents are verified only. A missing child is created with its reviewed descriptor only after the durable callback records the exact intent.
    Reset-TaskSecurityFixture $false
    $specs=@((New-TaskFolderSpec '\' $script:rootSddl VerifyExact),(New-TaskFolderSpec '\Ops\' $script:opsSddl VerifyExact),(New-TaskFolderSpec '\Ops\Daily\' $script:dailySddl CreateOnly))
    $callback={param($intent)if($intent.Kind -cne 'TaskFolderCreateIntent' -or $intent.Path -cne '\Ops\Daily\' -or $intent.SecurityHash -cne (Get-WsmHashText $script:dailySddl)){throw 'Incorrect durable folder creation intent'};$script:events+=@('Intent:'+ $intent.Path)}
    $prepared=Prepare-WsmTaskSecurityFolders -Folders $specs -BeforeCreate $callback -Scheduler $script:fixtureScheduler
    if($prepared.Folders.Count -ne 3 -or $prepared.OwnedReceipts.Count -ne 1 -or $prepared.OwnedReceipts[0].Kind -cne 'OwnedTaskFolder' -or $prepared.OwnedReceipts[0].Path -cne '\Ops\Daily\' -or $prepared.OwnedReceipts[0].SecurityHash -cne (Get-WsmHashText $script:dailySddl) -or (($script:events -join '|') -cne 'Intent:\Ops\Daily\|Create:\Ops\Daily\')){throw 'Folder create did not persist intent first or return the exact canonical owned receipt.'}
    $verified=Assert-WsmTaskSecurityFolders -Folders $specs -OwnedReceipts $prepared.OwnedReceipts -Scheduler $script:fixtureScheduler
    if(-not $verified.Passed -or $verified.Folders.Count -ne 3){throw 'Prepared nested folder security did not reverify exactly.'}

    # An existing CreateOnly path is never adopted without its matching receipt; VerifyExact never overwrites ACL drift.
    Assert-TaskSecurityThrows {Prepare-WsmTaskSecurityFolders -Folders $specs -BeforeCreate $callback -Scheduler $script:fixtureScheduler} 'existing CreateOnly folder without ownership receipt'
    $script:events=@();$tamperedSpecs=@((New-TaskFolderSpec '\Ops\' $script:rootSddl VerifyExact));Assert-TaskSecurityThrows {Prepare-WsmTaskSecurityFolders -Folders $tamperedSpecs -BeforeCreate $callback -Scheduler $script:fixtureScheduler} 'existing folder ACL drift';if(@($script:events | Where-Object {$_ -like 'Create:*'}).Count){throw 'Existing folder ACL drift was followed by a folder mutation.'}
    $badReceipt=$prepared.OwnedReceipts[0].PSObject.Copy();$badReceipt.SecurityHash=('0'*64);Assert-TaskSecurityThrows {Assert-WsmTaskSecurityFolders -Folders $specs -OwnedReceipts @($badReceipt) -Scheduler $script:fixtureScheduler} 'owned receipt hash drift'

    # Access denied and unrelated COM errors propagate; only FILE_NOT_FOUND/PATH_NOT_FOUND count as absent.
    Reset-TaskSecurityFixture $false;$script:denyPath='\Ops\Daily\';$beforeCount=$script:events.Count;Assert-TaskSecurityThrows {Prepare-WsmTaskSecurityFolders -Folders $specs -BeforeCreate $callback -Scheduler $script:fixtureScheduler} 'access denied is not absence';if($script:events.Count -ne $beforeCount){throw 'Access denial was mistaken for absence and triggered a create callback.'}
    foreach($hresult in @(-2147024894,-2147024893)){ $exception=New-Object System.Runtime.InteropServices.COMException('fixture missing',$hresult);$record=$null;try{throw $exception}catch{$record=$_};if(-not (Test-WsmTaskSecurityNotFoundError $record)){throw ('Expected missing HRESULT was not accepted: '+$hresult)} }
    $exception=New-Object System.Runtime.InteropServices.COMException('fixture denied',-2147024891);$record=$null;try{throw $exception}catch{$record=$_};if(Test-WsmTaskSecurityNotFoundError $record){throw 'Access denied HRESULT was treated as not found.'}
    Reset-TaskSecurityFixture $false;$failingCallback={param($intent)$script:events+=@('Intent:'+ $intent.Path);throw 'fixture journal persistence failed'};Assert-TaskSecurityThrows {Prepare-WsmTaskSecurityFolders -Folders $specs -BeforeCreate $failingCallback -Scheduler $script:fixtureScheduler} 'durable intent callback failure';if(@($script:events | Where-Object {$_ -like 'Create:*'}).Count){throw 'Folder was created after the durable intent callback failed.'}

    # A create whose readback differs from the reviewed descriptor cannot produce an ownership receipt.
    Reset-TaskSecurityFixture $false;$script:tamperCreated=$true;Assert-TaskSecurityThrows {Prepare-WsmTaskSecurityFolders -Folders $specs -BeforeCreate $callback -Scheduler $script:fixtureScheduler} 'create ACL readback mismatch';if(($script:events -join '|') -notmatch '^Intent:.*\|Create:'){throw 'Readback mismatch test did not prove intent-before-create ordering.'}
    $incomplete=@((New-TaskFolderSpec '\Ops\Daily\' $script:dailySddl CreateOnly));Assert-TaskSecurityThrows {ConvertTo-WsmTaskSecurityFolderSpecs $incomplete} 'missing reviewed ancestor ACL specification'
    Assert-TaskSecurityThrows {ConvertTo-WsmTaskSecurityFolderSpecs @((New-TaskFolderSpec '\Ops\' $script:opsSddl VerifyExact),(New-TaskFolderSpec '\ops\' $script:opsSddl VerifyExact))} 'duplicate case-insensitive folder path'
    Write-Host 'PASS: task security capture covers task and ancestors; target folder ACLs are verified or intent-journaled before create, read back exactly, and never overwrite unowned ACLs.'
}
