#requires -Version 5.1
# S12（PLAN 17.129）：「路徑在根底下」收斂成 Test-WsmPathWithinRoot／Get-WsmPathRelativeToRoot／Test-WsmPathOverlap 一份實作。
# 涵蓋：表格測試（兄弟前綴、等於根、磁碟根、UNC 根、大小寫、尾端分隔符、混用斜線、.. 逃逸、原生模式）、
# 每個呼叫端至少一條整合斷言（行為，或確認函式本體確實呼叫共用函式）、舊實作已刪除、靜態守門（不得再自寫 StartsWith(根+'\')）。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking 3>$null
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:passed=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:passed++}
function InModule([scriptblock]$Block,[object[]]$Arguments=@()){& $module $Block @Arguments}
function Rejects([scriptblock]$Block,[string]$Pattern,[string]$Message){
    $text='';try{[void](& $Block)}catch{$text=[string]$_.Exception.Message}
    if(-not $text){throw ($Message+' (nothing was thrown)')};if($text -notmatch $Pattern){throw ($Message+' (wrong error: '+$text+')')};$script:passed++
}

# ---------------------------------------------------------------- 1. Win32 模式表格：路徑、根、算在內、-ExcludeRoot 時算在內
$win32=@(
    @('C:\data\x','C:\data',$true,$true),
    @('C:\data2','C:\data',$false,$false),            # 兄弟前綴
    @('C:\data2\x','C:\data',$false,$false),
    @('C:\data-old\x','C:\data',$false,$false),
    @('C:\dat','C:\data',$false,$false),
    @('C:\data','C:\data',$true,$false),              # 等於根本身：預設算，-ExcludeRoot 不算
    @('C:\DATA\Sub','c:\data',$true,$true),           # 大小寫不同
    @('C:\data\x','C:\data\',$true,$true),            # 根有尾端分隔符
    @('C:\data\','C:\data',$true,$false),             # 路徑有尾端分隔符
    @('C:\data\','C:\data\',$true,$false),
    @('C:/data/x','C:\data',$true,$true),             # 混用 /
    @('C:\data/x/y','C:/data',$true,$true),
    @('C:\data\..\data2\x','C:\data',$false,$false),  # .. 逃逸到兄弟：先正規化
    @('C:\data\sub\..\x','C:\data',$true,$true),
    @('C:\data\..\x','C:\data',$false,$false),
    @('C:\data\..','C:\data',$false,$false),
    @('D:\x','C:\data',$false,$false),                # 不同磁碟
    @('C:\x\y','C:\',$true,$true),                    # 磁碟根：底下全部算在內
    @('C:\x','C:\',$true,$true),
    @('C:\','C:\',$true,$false),
    @('D:\x','C:\',$false,$false),
    @('\\srv\share\a','\\srv\share',$true,$true),     # UNC 根
    @('\\srv\share2\a','\\srv\share',$false,$false),
    @('\\srv\share2','\\srv\share',$false,$false),
    @('\\srv\share','\\srv\share',$true,$false),
    @('\\SRV\Share\A\','\\srv\share\a',$true,$false),
    @('\\srv\share\a','\\srv\share\',$true,$true),
    @('\\srv2\share\a','\\srv\share',$false,$false),
    @('\\srv\share\x','\\srv\share\a',$false,$false),
    @('\\srv\share\a','C:\',$false,$false),
    @('C:\data\x','\\srv\share',$false,$false)
)
foreach($row in $win32){
    $actual=InModule {param($p,$r) Test-WsmPathWithinRoot $p $r} @($row[0],$row[1])
    $strict=InModule {param($p,$r) Test-WsmPathWithinRoot $p $r -ExcludeRoot} @($row[0],$row[1])
    Check ($actual -eq $row[2]) ('Win32 within: '+$row[0]+' in '+$row[1]+' expected '+$row[2]+' got '+$actual)
    Check ($strict -eq $row[3]) ('Win32 within -ExcludeRoot: '+$row[0]+' in '+$row[1]+' expected '+$row[3]+' got '+$strict)
}

# ---------------------------------------------------------------- 2. 原生模式表格（\Device\... 與實體路徑）：字面比較，不走 GetFullPath
$native=@(
    @('\Device\HarddiskVolume9\business\one','\Device\HarddiskVolume9\business',$true,$true,'one'),
    @('\Device\HarddiskVolume90\business\one','\Device\HarddiskVolume9\business',$false,$false,$null),   # 磁碟區編號的兄弟前綴
    @('\Device\HarddiskVolume90','\Device\HarddiskVolume9',$false,$false,$null),
    @('\Device\HarddiskVolume9\business2','\Device\HarddiskVolume9\business',$false,$false,$null),
    @('\Device\HarddiskVolume9\business','\Device\HarddiskVolume9\business',$true,$false,''),
    @('\DEVICE\harddiskvolume9\BUSINESS\','\Device\HarddiskVolume9\business',$true,$false,''),
    @('\Device\HarddiskVolume9\business\a\b','\Device\HarddiskVolume9\business\',$true,$true,'a\b'),
    @('\Device\HarddiskVolume9\x','\Device\HarddiskVolume9',$true,$true,'x'),
    @('\Device\HarddiskVolume9\business\..\other','\Device\HarddiskVolume9\business',$false,$false,$null),  # 含 .. 的原生路徑無法字面判定：不算在內
    @('\Device\HarddiskVolume9\business\.\x','\Device\HarddiskVolume9\business',$false,$false,$null),
    @('\Device\HarddiskVolume9\business\x','\Device\HarddiskVolume9\business\..',$false,$false,$null),
    @('\Device\HarddiskVolume9\a/b','\Device\HarddiskVolume9\a',$false,$false,$null),                          # 原生模式不把 / 當分隔符（Win32 模式才會）
    @('','\Device\X',$false,$false,$null),
    @('\Device\X','',$false,$false,$null),
    @('\Device\X','\',$false,$false,$null),
    @('\\SRV\SHARE\X','\\SRV\SHARE',$true,$true,'X'),                                                          # RemoteStorage 比對用的大寫 UNC 形式
    @('\\SRV\SHARE2\X','\\SRV\SHARE',$false,$false,$null)
)
foreach($row in $native){
    $actual=InModule {param($p,$r) Test-WsmPathWithinRoot $p $r -Native} @($row[0],$row[1])
    $strict=InModule {param($p,$r) Test-WsmPathWithinRoot $p $r -Native -ExcludeRoot} @($row[0],$row[1])
    $relative=InModule {param($p,$r) Get-WsmPathRelativeToRoot $p $r -Native} @($row[0],$row[1])
    Check ($actual -eq $row[2]) ('Native within: '+$row[0]+' in '+$row[1]+' expected '+$row[2]+' got '+$actual)
    Check ($strict -eq $row[3]) ('Native within -ExcludeRoot: '+$row[0]+' in '+$row[1]+' expected '+$row[3]+' got '+$strict)
    if($row[2]){Check ([string]$relative -ceq [string]$row[4]) ('Native relative: '+$row[0]+' in '+$row[1]+' expected '+$row[4]+' got '+$relative)}
    else{Check ($null -eq $relative) ('Native relative must be null when the path is not within the root: '+$row[0]+' in '+$row[1])}
}
# 原生模式與 Win32 模式的差別要看得出來：同一組含 / 的輸入，Win32 模式正規化後算在內，原生模式不算。
Check (InModule {Test-WsmPathWithinRoot 'C:\Device\V\a/b' 'C:\Device\V\a'}) 'Win32 mode must normalise / separators.'
Check (-not (InModule {Test-WsmPathWithinRoot 'C:\Device\V\a/b' 'C:\Device\V\a' -Native})) 'Native mode must not normalise / separators.'

# ---------------------------------------------------------------- 3. 重疊（任一邊在另一邊底下，含相等；字面比較、不解讀 ..）
$overlap=@(
    @('C:\data','C:\data2',$false),
    @('C:\data2','C:\data',$false),
    @('C:\data\x','C:\data',$true),
    @('C:\data','C:\data\x',$true),
    @('C:\DATA','c:\data\',$true),
    @('C:\','C:\data',$true),
    @('\Device\HarddiskVolume9\b','\Device\HarddiskVolume9\b\c',$true),
    @('\Device\HarddiskVolume9\b2','\Device\HarddiskVolume9\b',$false),
    @('\Device\HarddiskVolume90','\Device\HarddiskVolume9',$false),
    @('','',$true),                                    # 既有行為：兩邊都空視為相等（防碰撞檢查寧可擋）
    @('C:\a\..\b','C:\a',$true)                        # 不解讀 ..：字面上在 C:\a 底下，防碰撞檢查寧可擋
)
foreach($row in $overlap){
    $actual=InModule {param($l,$r) Test-WsmPathOverlap $l $r} @($row[0],$row[1])
    Check ($actual -eq $row[2]) ('Overlap: '+$row[0]+' vs '+$row[1]+' expected '+$row[2]+' got '+$actual)
}

# ---------------------------------------------------------------- 4. 舊實作已刪除；定義只剩共用實作
foreach($name in @('Test-WsmAssistivePathWithin','Test-WsmWizardNonCProofHandoffWithin','Assert-WsmWizardNonCTargetHandoffWithin','Get-WsmWizardNonCPathUnderPhysicalRoot','Get-WsmWizardNonCPhysicalPathUnderRoot')){
    Check ($null -eq (InModule {param($n) Get-Command $n -ErrorAction SilentlyContinue} @($name))) ('The retired path-within implementation still exists: '+$name)
}
function Get-SrcAst([string]$Name){$t=$null;$e=$null;[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo ('src\'+$Name)),[ref]$t,[ref]$e)}
function Test-FunctionCalls([string]$File,[string]$Function,[string[]]$Callees){
    $ast=Get-SrcAst $File
    $defs=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Function},$true))
    if($defs.Count -ne 1){throw ('Expected exactly one definition of '+$Function+' in '+$File)}
    $calls=@($defs[0].FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object {$_.GetCommandName()})
    foreach($callee in $Callees){if($calls -cnotcontains $callee){throw ($Function+' ('+$File+') no longer calls the shared '+$callee)}}
    $script:passed++
}

# ---------------------------------------------------------------- 5. 每個呼叫端：函式本體確實呼叫共用函式（改回自寫比對就會紅）
$callers=@(
    @('AssistiveNonC.ps1','Assert-WsmAssistivePathUnder','Test-WsmPathWithinRoot'),
    @('AssistiveNonC.ps1','Assert-WsmAssistiveNonCTargetShareAlias','Test-WsmPathWithinRoot'),
    @('AssistiveNonC.ps1','ConvertTo-WsmAssistivePeerPath','Get-WsmPathRelativeToRoot'),
    @('AssistiveNonC.ps1','Assert-WsmAssistiveNonCImportSourceBinding','Test-WsmPathWithinRoot'),
    @('AssistiveNonC.ps1','Assert-WsmAssistiveNonCTransferContext','Test-WsmPathWithinRoot'),
    @('AssistiveNonC.ps1','Get-WsmAssistiveNonCScopeErrors','Test-WsmPathWithinRoot'),
    @('AssistiveNonC.ps1','Get-WsmAssistiveTransferScopeRows','Test-WsmPathWithinRoot'),
    @('AssistiveNonC.ps1','Invoke-WsmAssistiveNonCTransferCore','Test-WsmPathWithinRoot'),
    @('AssistiveNonC.ps1','New-WsmAssistiveNonCTransferPlan','Test-WsmPathWithinRoot'),
    @('WizardNonCProofHandoff.ps1','Get-WsmWizardNonCProofHandoffShares','Test-WsmPathWithinRoot'),
    @('WizardNonCProofHandoff.ps1','Get-WsmWizardNonCProofHandoffShareForPath','Test-WsmPathWithinRoot'),
    @('WizardNonCProofHandoff.ps1','ConvertTo-WsmWizardNonCTargetUncRoot','Test-WsmPathWithinRoot'),
    @('WizardNonCProofHandoff.ps1','Get-WsmWizardNonCProofHandoffPreview','Test-WsmPathWithinRoot'),
    @('WizardNonCProofHandoff.ps1','Get-WsmWizardNonCProofHandoffStage','Test-WsmPathWithinRoot'),
    @('WizardNonCTargetHandoff.ps1','Export-WsmWizardNonCTargetHandoff','Test-WsmPathWithinRoot'),
    @('WizardNonCTargetHandoff.ps1','Get-WsmWizardNonCTargetActiveReceipt','Test-WsmPathWithinRoot'),
    @('WizardNonCTargetHandoff.ps1','Get-WsmWizardNonCTargetHandoffStage','Test-WsmPathWithinRoot'),
    @('WizardNonCTargetHandoff.ps1','Set-WsmWizardNonCTargetActiveReceipt','Test-WsmPathWithinRoot'),
    @('WizardNonCAccountObservation.ps1','Get-WsmWizardNonCSourceProofForCollection','Get-WsmPathRelativeToRoot'),
    @('RemoteStorageContracts.ps1','Test-WsmRemotePathOverlap','Test-WsmPathOverlap'),
    @('RemoteStorageContracts.ps1','Test-WsmRemoteStorageCoversPath','Test-WsmPathWithinRoot'),
    @('AdvancedReview.ps1','Get-WsmMappingIssues','Test-WsmPathOverlap'),
    @('WizardBackup.ps1','Test-WsmIndependentCopyInsideWorkspace','Test-WsmPathWithinRoot'),
    @('PhysicalPaths.ps1','Test-WsmPathOverlap','Get-WsmPathRelativeToRoot'),
    @('PhysicalPaths.ps1','Test-WsmPathWithinRoot','Get-WsmPathRelativeToRoot')
)
foreach($row in $callers){Test-FunctionCalls $row[0] $row[1] @($row[2])}
# A1 的獨立副本包含檢查兩段都收斂：Win32 一次、實體路徑（原生）一次。
$a1=@((Get-SrcAst 'WizardBackup.ps1').FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Test-WsmIndependentCopyInsideWorkspace'},$true))[0]
$a1Calls=@($a1.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Test-WsmPathWithinRoot'},$true))
Check ($a1Calls.Count -eq 2 -and @($a1Calls|Where-Object {$_.Extent.Text -match '-Native'}).Count -eq 1) 'The independent-copy containment check must use the shared function once in Win32 mode and once in native mode.'

# ---------------------------------------------------------------- 6. 呼叫端行為（兄弟前綴、等於根、.. 逃逸、混用斜線）
$base=Join-Path ([IO.Path]::GetTempPath()) ('wsm-pathroot-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($base)
try{
    $data=Join-Path $base 'data';$data2=Join-Path $base 'data2'
    [void][IO.Directory]::CreateDirectory($data);[void][IO.Directory]::CreateDirectory((Join-Path $data 'child'));[void][IO.Directory]::CreateDirectory($data2)

    # Assert-WsmAssistivePathUnder：回傳完整路徑；兄弟前綴與 .. 逃逸必須拒絕；等於根算在內。
    $child=Join-Path $data 'child\file.txt'
    Check ((InModule {param($p,$r) Assert-WsmAssistivePathUnder $p @($r) 'Test path'} @($child,$data)) -ceq [IO.Path]::GetFullPath($child)) 'A child path was not returned by Assert-WsmAssistivePathUnder.'
    Check ((InModule {param($p,$r) Assert-WsmAssistivePathUnder $p @($r) 'Test path'} @($data,$data)) -ceq [IO.Path]::GetFullPath($data)) 'The root itself must be accepted by Assert-WsmAssistivePathUnder.'
    Rejects {InModule {param($p,$r) Assert-WsmAssistivePathUnder $p @($r) 'Test path'} @((Join-Path $data2 'x.txt'),$data)} 'outside' 'A sibling-prefix path was accepted by Assert-WsmAssistivePathUnder.'
    Rejects {InModule {param($p,$r) Assert-WsmAssistivePathUnder $p @($r) 'Test path'} @(($data+'\..\data2\x.txt'),$data)} 'outside' 'A .. escape to a sibling was accepted by Assert-WsmAssistivePathUnder.'
    Check ((InModule {param($p,$r) Assert-WsmAssistivePathUnder $p @($r) 'Test path'} @(($data.Replace('\','/')+'/child/file.txt'),$data)) -ceq [IO.Path]::GetFullPath($child)) 'Mixed separators were not normalised by Assert-WsmAssistivePathUnder.'

    # Get-WsmMappingIssues（AdvancedReview）：兄弟目錄不算重疊；巢狀與同名（大小寫不同）算。
    Check (@(InModule {param($a,$b) Get-WsmMappingIssues (@([pscustomobject]@{ItemId='i1';Decision='Include';Mapping=$a},[pscustomobject]@{ItemId='i2';Decision='Include';Mapping=$b}))} @('D:\Payroll','D:\Payroll2')).Count -eq 0) 'Sibling-prefix target mappings were reported as overlapping.'
    Check (@(InModule {param($a,$b) Get-WsmMappingIssues (@([pscustomobject]@{ItemId='i1';Decision='Include';Mapping=$a},[pscustomobject]@{ItemId='i2';Decision='Include';Mapping=$b}))} @('D:\Payroll','d:\payroll\child')).Count -ge 1) 'Nested target mappings were not reported as overlapping.'
    Check (@(InModule {param($a,$b) Get-WsmMappingIssues (@([pscustomobject]@{ItemId='i1';Decision='Include';Mapping=$a},[pscustomobject]@{ItemId='i2';Decision='Include';Mapping=$b}))} @('D:\Payroll','d:\PAYROLL\')).Count -ge 1) 'Equal (case/trailing-separator different) target mappings were not reported as overlapping.'

    # Test-WsmRemotePathOverlap／Test-WsmRemoteStorageCoversPath（RemoteStorageContracts）
    Check (-not (InModule {Test-WsmRemotePathOverlap '\\srv\share\root\app' '\\srv\share\root\app2'})) 'Sibling-prefix remote paths were reported as overlapping.'
    Check (InModule {Test-WsmRemotePathOverlap '\\srv\share\root\app\x' '\\srv\share\root\APP'}) 'Nested remote paths were not reported as overlapping.'
    Check (InModule {Test-WsmRemotePathOverlap '\\srv\share\root\app' '\\SRV\Share\Root\app\'}) 'Equal remote paths were not reported as overlapping.'
    $remote=[pscustomobject]@{
        Source=[pscustomobject]@{RelativePath='app';Aliases=@([pscustomobject]@{Kind='Direct';RootUnc='\\srv\share\root'})}
        Target=[pscustomobject]@{RelativePath='';Aliases=@([pscustomobject]@{Kind='Direct';RootUnc='\\tgt\apps\root'})}
    }
    Check (InModule {param($r) Test-WsmRemoteStorageCoversPath $r '\\srv\share\root\app\data\file.cfg'} @($remote)) 'A path under the remote scope was not covered.'
    Check (InModule {param($r) Test-WsmRemoteStorageCoversPath $r '\\SRV\SHARE\ROOT\APP'} @($remote)) 'The remote scope root itself (different case) was not covered.'
    Check (-not (InModule {param($r) Test-WsmRemoteStorageCoversPath $r '\\srv\share\root\app2\data'} @($remote))) 'A sibling-prefix path was covered by the remote scope.'
    Check (-not (InModule {param($r) Test-WsmRemoteStorageCoversPath $r '\\srv\share2\root\app\data'} @($remote))) 'A sibling share was covered by the remote scope.'
    Check (-not (InModule {param($r) Test-WsmRemoteStorageCoversPath $r '\\srv\share\root\app\..\other\data'} @($remote))) 'A .. escape was covered by the remote scope.'
    Check (InModule {param($r) Test-WsmRemoteStorageCoversPath $r '\\tgt\apps\root\anything\x'} @($remote)) 'A path under the target scope root (empty relative path) was not covered.'

    # Test-WsmIndependentCopyInsideWorkspace（A1）：Win32 與實體路徑兩段。
    Check (-not (InModule {param($l,$w) Test-WsmIndependentCopyInsideWorkspace $l $w} @((Join-Path $data2 'copy'),$data))) 'A sibling-prefix copy destination was treated as inside the workspace.'
    Check (InModule {param($l,$w) Test-WsmIndependentCopyInsideWorkspace $l $w} @((Join-Path $data 'child\copy'),$data)) 'A copy destination below the workspace was not detected.'
    Check (InModule {param($l,$w) Test-WsmIndependentCopyInsideWorkspace $l $w} @($data,$data)) 'A copy destination equal to the workspace was not detected.'
    Check (InModule {param($l,$w) Test-WsmIndependentCopyInsideWorkspace $l $w} @(($data.ToUpperInvariant()+'\child'),$data)) 'A case-different copy destination below the workspace was not detected.'
    Check (-not (InModule {param($l,$w) Test-WsmIndependentCopyInsideWorkspace $l $w} @(($data+'\..\data2\copy'),$data))) 'A .. path that leaves the workspace was treated as inside it.'
    Check (InModule {param($l,$w) Test-WsmIndependentCopyInsideWorkspace $l $w} @(($data+'\child\..\..\data\x'),$data)) 'A .. path that stays in the workspace was not detected.'

    # ConvertTo-WsmAssistivePeerPath：實體路徑的相對路徑；兄弟目錄拒絕。
    $peerProof=[pscustomobject]@{PeerName='fixture-peer';ShareName='ShareOne';LocalPhysicalRoot=(InModule {param($p) Get-WsmPhysicalPath $p} @($data))}
    Check ((InModule {param($p,$q) ConvertTo-WsmAssistivePeerPath $p $q} @((Join-Path $data 'child\file.txt'),$peerProof)) -ceq '\\fixture-peer\ShareOne\child\file.txt') 'A path below the peer share root was not converted to its UNC path.'
    Check ((InModule {param($p,$q) ConvertTo-WsmAssistivePeerPath $p $q} @($data,$peerProof)) -ceq '\\fixture-peer\ShareOne') 'The peer share root itself was not converted to the bare share UNC.'
    Rejects {InModule {param($p,$q) ConvertTo-WsmAssistivePeerPath $p $q} @((Join-Path $data2 'x'),$peerProof)} 'outside the reviewed peer share' 'A sibling-prefix local path was converted to a peer share path.'

    # WizardNonCProofHandoff：目標根必須在選定的 share 根底下；兄弟前綴與 .. 逃逸拒絕；巢狀 share 拒絕、兄弟 share 可並存。
    $uncRoot=InModule {param($r,$s) ConvertTo-WsmWizardNonCTargetUncRoot $r $s 'ShareOne' 'fixture-peer'} @((Join-Path $data 'child'),$data)
    Check ($uncRoot -ceq '\\fixture-peer\ShareOne\child') ('A target root below the share was not converted: '+$uncRoot)
    Rejects {InModule {param($r,$s) ConvertTo-WsmWizardNonCTargetUncRoot $r $s 'ShareOne' 'fixture-peer'} @($data2,$data)} 'inside the explicitly selected' 'A sibling-prefix target root was accepted inside the share root.'
    Rejects {InModule {param($r,$s) ConvertTo-WsmWizardNonCTargetUncRoot $r $s 'ShareOne' 'fixture-peer'} @(($data+'\..\data2'),$data)} 'inside the explicitly selected' 'A .. target root escaping to a sibling was accepted inside the share root.'
    $shares=InModule {param($a,$b) Get-WsmWizardNonCProofHandoffShares 'ShareOne' $a @([pscustomobject]@{ShareName='ShareTwo';LocalPath=$b})} @($data,$data2)
    Check (@($shares).Count -eq 2) 'Sibling-prefix share roots must be accepted side by side.'
    Rejects {InModule {param($a,$b) Get-WsmWizardNonCProofHandoffShares 'ShareOne' $a @([pscustomobject]@{ShareName='ShareTwo';LocalPath=$b})} @($data,(Join-Path $data 'child'))} 'Nested or overlapping' 'Nested share roots were accepted.'
    Check ((InModule {param($p,$s) (Get-WsmWizardNonCProofHandoffShareForPath $p $s).Name} @((Join-Path $data2 'x'),$shares)) -ceq 'ShareTwo') 'A path below the second share was matched to the wrong share.'
    Rejects {InModule {param($p,$s) Get-WsmWizardNonCProofHandoffShareForPath $p $s} @((Join-Path $base 'data3\x'),$shares)} 'covered by exactly one' 'A path below neither share was accepted.'

    # Get-WsmWizardNonCSourceProofForCollection：原生路徑的兄弟前綴不得命中。
    $proofRows=@([pscustomobject]@{SHA256=('a'*64);Proof=[pscustomobject]@{LocalPhysicalRoot='\Device\HarddiskVolume9\business';PeerName='source-peer';ShareName='ShareOne'}})
    Check ($null -eq (InModule {param($r) Get-WsmWizardNonCSourceProofForCollection ([pscustomobject]@{PhysicalPath='\Device\HarddiskVolume9\business2\x'}) $r} @(,$proofRows))) 'A sibling-prefix native collection path matched a peer share root.'
    Check ((InModule {param($r) (Get-WsmWizardNonCSourceProofForCollection ([pscustomobject]@{PhysicalPath='\Device\HarddiskVolume9\business\x'}) $r).SourceRoot} @(,$proofRows)) -ceq '\\source-peer\ShareOne\x') 'A native collection path below a peer share root was not matched.'
    Check ($null -eq (InModule {param($r) Get-WsmWizardNonCSourceProofForCollection ([pscustomobject]@{PhysicalPath='\Device\HarddiskVolume9\business/x'}) $r} @(,$proofRows))) 'A native collection path must be compared literally (a / is not a separator in native mode).'
    Check ($null -eq (InModule {param($r) Get-WsmWizardNonCSourceProofForCollection ([pscustomobject]@{PhysicalPath='\Device\HarddiskVolume9\business\..\other'}) $r} @(,$proofRows))) 'A native collection path with a .. segment matched a peer share root.'
}finally{
    $full=[IO.Path]::GetFullPath($base);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if([IO.Path]::GetDirectoryName($full) -ine $temp -or [IO.Path]::GetFileName($full) -notlike 'wsm-pathroot-*'){throw 'Unsafe path-within-root test cleanup path.'}
    if([IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue}
}

# ---------------------------------------------------------------- 7. 靜態守門：src 不得再自寫「StartsWith(根+'\')」前綴比對
# 判定：String.StartsWith 的第一個引數含「+'\'」，或是名稱含 prefix／parent／root 的變數（預先組好的前綴）。
# 例外清單是檔案 → 允許的筆數；筆數變多（新增自寫比對）或變少（已收斂但清單沒更新）都會失敗，所以清單只會縮小。
$allowed=[ordered]@{
    # 唯一實作與白名單內刻意保留的相對路徑比對
    'PhysicalPaths.ps1'=@(1,'共用實作本身（Get-WsmPathRelativeToRoot）')
    'AssistiveNonC.ps1'=@(3,'相對路徑對排除清單／設定檔清單的比對（枚舉熱迴圈與相對路徑，不是「根」判定；改成函式呼叫會讓大目錄枚舉變慢）')
    'WizardNonCAccountObservation.ps1'=@(1,'相對路徑對排除清單的比對（枚舉熱迴圈）')
    'WizardBackup.ps1'=@(1,'進度顯示：把前綴剝掉取相對路徑，找不到前綴就退回檔名（顯示用途，不是安全判定）')
    # 以下檔案不在 F2 白名單（S12 規格要求先回報清單、不直接改）；PLAN 17.129 列出，之後逐批收斂並從此清單移除
    'AssistiveComparison.ps1'=@(1,'F2 白名單外，待後續批次收斂')
    'AssistiveContracts.ps1'=@(1,'F2 白名單外，待後續批次收斂')
    'AssistiveFiles.ps1'=@(5,'F2 白名單外，待後續批次收斂')
    'AssistiveOsProvided.ps1'=@(2,'F2 白名單外，待後續批次收斂')
    'AssistiveProbe.ps1'=@(1,'F2 白名單外，待後續批次收斂')
    'AssistiveReports.ps1'=@(2,'F2 白名單外，待後續批次收斂')
    'AssistiveResources.ps1'=@(2,'F2 白名單外，待後續批次收斂')
    'AssistiveRestore.ps1'=@(4,'F2 白名單外，待後續批次收斂')
    'AssistiveSettingsForms.ps1'=@(1,'F2 白名單外，待後續批次收斂')
    'AssistiveTargetPreparation.ps1'=@(1,'F2 白名單外，待後續批次收斂')
    'ConfigArtifactContracts.ps1'=@(2,'F2 白名單外，待後續批次收斂')
    'DeltaVolumeTransport.ps1'=@(3,'F2 白名單外，待後續批次收斂')
    'DeltaWorkflow.ps1'=@(1,'F2 白名單外，待後續批次收斂')
    'DeveloperProbe.ps1'=@(2,'F2 白名單外，待後續批次收斂')
    'EnvironmentConfirmation.ps1'=@(1,'F2 白名單外，待後續批次收斂')
    'FileScopeGuard.ps1'=@(7,'F2 白名單外，待後續批次收斂')
    'HtmlConsole.ps1'=@(3,'F2 白名單外，待後續批次收斂')
    'LabValidation.ps1'=@(2,'F2 白名單外，待後續批次收斂')
    'MigrationContracts.ps1'=@(4,'F2 白名單外，待後續批次收斂')
    'OracleClientContracts.ps1'=@(7,'F2 白名單外，待後續批次收斂')
    'OutputWorkspace.ps1'=@(1,'F2 白名單外，待後續批次收斂')
    'PackageTransport.ps1'=@(1,'F2 白名單外，待後續批次收斂')
    'Payload.ps1'=@(7,'F2 白名單外，待後續批次收斂')
    'Recovery.ps1'=@(3,'F2 白名單外，待後續批次收斂')
    'Restore.ps1'=@(2,'F2 白名單外，待後續批次收斂')
    'ShareQuiescence.ps1'=@(1,'F2 白名單外，待後續批次收斂')
    'SourceCandidateConfirmation.ps1'=@(20,'F2 白名單外，待後續批次收斂')
    'SourceCandidateDiscovery.ps1'=@(9,'F2 白名單外，待後續批次收斂')
    'WizardBackupProjection.ps1'=@(3,'F2 白名單外，待後續批次收斂')
    'WizardDetails.ps1'=@(2,'F2 白名單外，待後續批次收斂')
    'WizardFlow.ps1'=@(4,'F2 白名單外，待後續批次收斂')
    'WizardNonC.ps1'=@(2,'F2 白名單外，待後續批次收斂')
    'WizardNonCOperations.ps1'=@(2,'F2 白名單外，待後續批次收斂')
    'WizardPreparation.ps1'=@(3,'F2 白名單外（S12 規格只授權 Q2c），待後續批次收斂')
    'WizardPreparationBulk.ps1'=@(1,'F2 白名單外，待後續批次收斂')
    'WizardRestore.ps1'=@(2,'F2 白名單外，待後續批次收斂')
    'WizardRuntime.ps1'=@(3,'F2 白名單外，待後續批次收斂')
    'WorkloadDiscovery.ps1'=@(4,'F2 白名單外，待後續批次收斂')
}
$found=@{}
foreach($file in Get-ChildItem (Join-Path $repo 'src') -Filter '*.ps1' -File){
    $ast=Get-SrcAst $file.Name
    $hits=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -ceq 'StartsWith' -and $n.Arguments.Count -ge 1},$true)|Where-Object {
        $argument=$_.Arguments[0]
        ($argument.Extent.Text -match "\+\s*['""]\\['""]") -or (($argument -is [Management.Automation.Language.VariableExpressionAst]) -and $argument.VariablePath.UserPath -match '(?i)prefix|parent|root')
    })
    if($hits.Count){$found[$file.Name]=$hits.Count}
}
foreach($name in $found.Keys){
    Check ($allowed.Contains($name)) ('src\'+$name+' has a hand-written root-prefix comparison ('+$found[$name]+'); use Test-WsmPathWithinRoot / Get-WsmPathRelativeToRoot / Test-WsmPathOverlap (S12).')
    Check ($found[$name] -le $allowed[$name][0]) ('src\'+$name+' gained a hand-written root-prefix comparison: '+$found[$name]+' > '+$allowed[$name][0]+'. Use the shared function.')
}
foreach($name in $allowed.Keys){
    $count=0;if($found.ContainsKey($name)){$count=$found[$name]}
    Check ($count -eq $allowed[$name][0]) ('The exception list is stale for src\'+$name+': allowed '+$allowed[$name][0]+', found '+$count+'. Update tests\Test-PathWithinRoot.ps1.')
}

Write-Host ('PASS: shared path-within-root (Win32 and native modes), every caller, retired implementations and static guard ('+$script:passed+' checks).')
