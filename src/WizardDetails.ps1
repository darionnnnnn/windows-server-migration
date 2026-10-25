# N9c2 / R7-07: 顯示原字串、解析結果與解析依據的唯讀投影。只讀 item 內已保存的欄位；不展開環境變數、不讀本機環境。
function ConvertTo-WsmPathDisplayText($Value,[int]$MaximumLength=2048) {
    # 路徑是資料，不是標記：控制字元／雙向覆寫字元改成可見的 \uXXXX，內嵌機密指派遮蔽，長度設上限。
    if($null -eq $Value){return ''}
    $text=[string]$Value
    $text=Protect-WsmSensitiveAssignmentText $text
    $builder=New-Object System.Text.StringBuilder
    foreach($char in $text.ToCharArray()){
        $category=[Globalization.CharUnicodeInfo]::GetUnicodeCategory($char)
        if($category -eq [Globalization.UnicodeCategory]::Control -or $category -eq [Globalization.UnicodeCategory]::Format -or $category -eq [Globalization.UnicodeCategory]::LineSeparator -or $category -eq [Globalization.UnicodeCategory]::ParagraphSeparator){[void]$builder.Append('\u'+([int]$char).ToString('X4'))}else{[void]$builder.Append($char)}
        if($builder.Length -ge $MaximumLength){break}
    }
    $result=$builder.ToString();if($result.Length -gt $MaximumLength){$result=$result.Substring(0,$MaximumLength)}
    $result
}

function Get-WsmPathResolutionBasisLabel([string]$Basis) {
    switch -CaseSensitive ($Basis) { 'Machine'{'機器層'} 'ProfileDerived'{'帳號設定檔推導'} 'Literal'{'字面路徑'} default{'未解析'} }
}

function Get-WsmPathResolutionReasonInfo([string]$Reason) {
    $text=switch -CaseSensitive ($Reason) {
        {$_ -in @('AccountHasNoProfile','NoAccountForProfileVariable','ProfilePathNotResolvable','ProfileVariableUnresolved')} {@('找不到可用的帳號設定檔','在新機確認該帳號的設定檔路徑')}
        {$_ -in @('VariableNotInSourceContext','ExpansionLimit')} {@('自訂或來源未記錄的環境變數','確認變數在新機的值')}
        'ExcludedSecretVariable' {@('變數含機密，值未保存','確認變數在新機的值（工具不保存機密值，只顯示名稱）')}
        'UserScopedVariable' {@('TEMP／TMP 屬於執行帳號本身','在新機確認執行帳號的 TEMP／TMP 路徑')}
        'NoSourceContext' {@('來源沒有留下解析依據','重新在來源機執行盤點，或人工確認實際路徑')}
        'RelativeOrNonAbsolutePath' {@('相對路徑，無法判定基準目錄','人工確認此路徑相對於哪個目錄')}
        'ParentOrCurrentSegment' {@('路徑含 . 或 .. 區段','人工確認實際的絕對路徑')}
        'EmptyPath' {@('路徑為空','人工確認此項目是否仍需搬移')}
        default {@('未記錄原因','人工確認此路徑在新機的實際位置')}
    }
    [pscustomobject][ordered]@{label=$text[0];nextStep=$text[1]}
}

function New-WsmPathResolutionView {
    # Context 只用來查「被排除的機密變數名稱」；環境變數的值從不進入回傳物件。
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Original,[AllowNull()][AllowEmptyString()][string]$Resolved,[string]$Basis,[AllowNull()][AllowEmptyString()][string]$Reason='',[object[]]$Variables=@(),$Context=$null,$MigrationSpec=$null)
    $names=New-Object 'System.Collections.Generic.List[string]'
    foreach($name in @($Variables)){if($null -ne $name -and ([string]$name) -and -not $names.Contains([string]$name)){$names.Add([string]$name)}}
    if(-not $names.Count -and $Original){foreach($m in [regex]::Matches($Original,'%([^%\\/:*?"<>|\r\n]+)%')){$n=$m.Groups[1].Value;if(-not $names.Contains($n)){$names.Add($n)}}}
    $excludedNames=@();if($null -ne $Context -and $Context.PSObject.Properties['ExcludedEnvironmentNames']){$excludedNames=@($Context.ExcludedEnvironmentNames|ForEach-Object {[string]$_})}
    $variableRows=@(foreach($name in $names){[pscustomobject][ordered]@{name=(ConvertTo-WsmPathDisplayText $name 256);excluded=[bool](($excludedNames -contains $name) -or ((Test-WsmSensitiveName $name) -or $name -match '(?i)private'))}})
    $known=@('Machine','ProfileDerived','Literal','Unresolved')
    $effectiveBasis=if($Basis -cin $known){$Basis}else{'Unresolved'}
    $unresolved=($effectiveBasis -ceq 'Unresolved' -or [string]::IsNullOrWhiteSpace($Resolved))
    if($unresolved){$effectiveBasis='Unresolved'}
    $code=[string]$Reason
    if($unresolved -and -not $code){
        $lower=@($names|ForEach-Object {$_.ToLowerInvariant()})
        if(@($variableRows|Where-Object excluded).Count){$code='ExcludedSecretVariable'}
        elseif(@($lower|Where-Object {$_ -in @('userprofile','appdata','localappdata')}).Count){$code='ProfileVariableUnresolved'}
        elseif($names.Count){$code='VariableNotInSourceContext'}
        elseif($Original -match '(^|[\\/])\.{1,2}([\\/]|$)'){$code='ParentOrCurrentSegment'}
        elseif([string]::IsNullOrWhiteSpace($Original)){$code='EmptyPath'}
        else{$code='RelativeOrNonAbsolutePath'}
    }
    $info=$null;if($unresolved){$info=Get-WsmPathResolutionReasonInfo $code}
    $view=[pscustomobject][ordered]@{
        original=(ConvertTo-WsmPathDisplayText $Original)
        resolved=$(if($unresolved){$null}else{ConvertTo-WsmPathDisplayText $Resolved})
        resolvedText=$(if($unresolved){'未解析'}else{ConvertTo-WsmPathDisplayText $Resolved})
        basis=$effectiveBasis
        basisLabel=(Get-WsmPathResolutionBasisLabel $effectiveBasis)
        unresolved=$unresolved
        manual=$unresolved
        reasonCode=$(if($unresolved){$code}else{''})
        reasonLabel=$(if($unresolved){$info.label}else{''})
        nextStep=$(if($unresolved){$info.nextStep}else{''})
        variables=@($variableRows)
    }
    # Q2: UNC 路徑要明列責任（沿用既有外部共享／另行遷移）與證據；解析結果優先，沒有解析結果時看原字串。
    $uncPath='';if(-not $unresolved -and (Test-WsmUncPath $Resolved)){$uncPath=$Resolved}elseif(Test-WsmUncPath $Original){$uncPath=$Original}
    if($uncPath){$unc=Get-WsmUncResponsibility $uncPath $MigrationSpec;if($unc){$view|Add-Member NoteProperty uncResponsibility $unc}}
    $view
}

function Get-WsmItemPathResolutionView($Item,$Context=$null) {
    # Discovery 候選與 WorkloadDiscovery 的 web.config 根；沒有 ResolutionBasis 的舊資料不推測依據。
    if(-not $Item -or -not $Item.PSObject.Properties['Settings'] -or -not $Item.Settings){return $null}
    # Settings 可能是記憶體中的雜湊表（剛盤點）或 JSON 載回的物件，兩種都要讀得到。
    $settings=$Item.Settings
    $spec=$null;if($Item.PSObject.Properties['MigrationSpec'] -and $Item.MigrationSpec){$spec=$Item.MigrationSpec}
    $basis=Get-WsmWorkloadSettingValue $settings 'ResolutionBasis'
    if($null -eq $basis){return $null}
    $original=Get-WsmWorkloadSettingValue $settings 'OriginalPath'
    if($null -ne $original){
        $variables=@(Get-WsmWorkloadSettingValue $settings 'ResolutionVariables')
        return (New-WsmPathResolutionView -Original ([string]$original) -Resolved ([string](Get-WsmWorkloadSettingValue $settings 'ResolvedCandidate')) -Basis ([string]$basis) -Reason '' -Variables $variables -Context $Context -MigrationSpec $spec)
    }
    $root=Get-WsmWorkloadSettingValue $settings 'PhysicalRoot'
    if($null -ne $root){
        return (New-WsmPathResolutionView -Original ([string]$root) -Resolved '' -Basis ([string]$basis) -Reason ([string](Get-WsmWorkloadSettingValue $settings 'ResolutionReason')) -Variables @() -Context $Context -MigrationSpec $spec)
    }
    $null
}

function Get-WsmCoveragePathResolutionView($Items,$Probe,$Context=$null) {
    # ConsumerPathResolution / SourcePathUnresolved coverage rows -> the consumer's original string and why it stayed unresolved.
    if($null -eq $Probe){return $null}
    $kind='';if($Probe -is [Collections.IDictionary]){if($Probe.Contains('ErrorKind')){$kind=[string]$Probe['ErrorKind']};$itemId=if($Probe.Contains('ItemId')){[string]$Probe['ItemId']}else{''}}
    else{if($Probe.PSObject.Properties['ErrorKind']){$kind=[string]$Probe.ErrorKind};$itemId=if($Probe.PSObject.Properties['ItemId']){[string]$Probe.ItemId}else{''}}
    if($kind -cne 'SourcePathUnresolved' -or -not $itemId){return $null}
    foreach($item in @($Items)){if($item -and $item.PSObject.Properties['ItemId'] -and [string]$item.ItemId -ceq $itemId){return (Get-WsmConsumerPathResolutionView $item $Context)}}
    $null
}

function Get-WsmConsumerPathResolutionView($Item,$Context=$null) {
    # Software coverage 的 ConsumerPathResolution（SourcePathUnresolved）：從消費者項目取回原字串。
    # 有 Context 就交給唯一的解析函式取得真正原因；沒有就只從原字串分類，不展開、不讀本機環境。
    if(-not $Item -or -not $Item.PSObject.Properties['Settings'] -or -not $Item.Settings -or $null -eq (Get-WsmWorkloadSettingValue $Item.Settings 'Xml')){return $null}
    $raw='';$sid=$null
    try{
        $xmlText=[string](Get-WsmWorkloadSettingValue $Item.Settings 'Xml')
        if($xmlText -match '<!DOCTYPE|<!ENTITY'){return $null}
        $xml=[xml]$xmlText
        if([string]$Item.Kind -ceq 'ScheduledTask'){$node=$xml.SelectSingleNode("//*[local-name()='Command']");if($node){$raw=[string]$node.InnerText};if($Context){$sid=Get-WsmSourceAccountSid $Context (Get-WsmTaskPrincipalAccount $xmlText)}}
        elseif([string]$Item.Kind -ceq 'IISSite'){$node=$xml.SelectSingleNode('//*[@physicalPath]');if($node){$raw=[string]$node.GetAttribute('physicalPath')}}
    }catch{return $null}
    if([string]::IsNullOrWhiteSpace($raw)){return $null}
    $reason='';$variables=@()
    if($null -ne $Context){$resolution=Resolve-WsmSourcePath $raw $Context $sid;$variables=@($resolution.Variables);if($null -eq $resolution.Resolved){$reason=[string]$resolution.Reason}}
    $view=New-WsmPathResolutionView -Original $raw -Resolved '' -Basis 'Unresolved' -Reason $reason -Variables $variables -Context $Context
    $view
}

# P3: PathCandidate 來源路徑「解析失敗」的唯一判定，草稿端（Get-WsmMigrationSpecDraft）與表單端（Get-WsmWizardPreparationReview）共用。
# 解析失敗：ResolutionBasis 為 Unresolved；有 Basis 但沒有解析結果；舊資料（無 Basis）沒有 ResolvedCandidate 且原字串不是絕對本機路徑或 UNC（含 %、相對路徑、. 或 .. 區段）。
function Test-WsmPathCandidateUnresolved($Settings) {
    if($null -eq $Settings){return $true}
    $original=[string](Get-WsmWorkloadSettingValue $Settings 'OriginalPath')
    $resolved=[string](Get-WsmWorkloadSettingValue $Settings 'ResolvedCandidate')
    $basis=Get-WsmWorkloadSettingValue $Settings 'ResolutionBasis'
    if($null -ne $basis){return ([string]$basis -ceq 'Unresolved' -or [string]::IsNullOrWhiteSpace($resolved))}
    if(-not [string]::IsNullOrWhiteSpace($resolved)){return $false}
    if([string]::IsNullOrWhiteSpace($original)){return $true}
    if($original.Contains('%') -or $original -match '(^|[\\/])\.{1,2}([\\/]|$)'){return $true}
    return -not ($original -match '^[A-Za-z]:[\\/]' -or $original -match '^\\\\[^\\/]+[\\/][^\\/]+')
}

function New-WsmUnresolvedSourcePathProvenance($Settings,[string]$ReviewHash) {
    $original=[string](Get-WsmWorkloadSettingValue $Settings 'OriginalPath')
    $variables=@(Get-WsmWorkloadSettingValue $Settings 'ResolutionVariables'|Where-Object {$null -ne $_})
    $view=New-WsmPathResolutionView -Original $original -Resolved '' -Basis 'Unresolved' -Reason '' -Variables $variables
    [pscustomobject][ordered]@{kind='UnresolvedSourcePath';originalPath=$view.original;reasonCode=$view.reasonCode;reason=$view.reasonLabel;nextStep=('請補登此項目實際的來源絕對路徑（'+$view.nextStep+'）；補登前不預填、不採用原字串，也不能核准。');reviewHash=$ReviewHash;freshness='來源路徑未解析，沒有可信的來源路徑可帶入；原字串只供顯示。'}
}

function Get-WsmWizardFileDetails($Item) {
    # Projection only: never touch a source filesystem during GET/polling.
    $rows=New-Object 'System.Collections.Generic.List[object]'
    $seen=@{}
    function Add-Detail([string]$Path,[string]$Status,[string]$Hash,[string]$Reason,$Resolution=$null) {
        if(-not $Path -or $seen.ContainsKey($Path.ToLowerInvariant())){return}
        $seen[$Path.ToLowerInvariant()]=$true
        $row=[ordered]@{path=$Path;status=$Status;sha256=$Hash;reason=$Reason;contentRead=$false}
        if($null -ne $Resolution){$row.resolution=$Resolution}
        else{$uncSpec=$null;if($Item.PSObject.Properties['MigrationSpec'] -and $Item.MigrationSpec){$uncSpec=$Item.MigrationSpec};$unc=Get-WsmUncResponsibility $Path $uncSpec;if($unc){$row.uncResponsibility=$unc}}
        $rows.Add([pscustomobject]$row)
    }
    if($Item.PSObject.Properties['Settings'] -and $Item.Settings){
        $settings=$Item.Settings
        if($settings.PSObject.Properties['Path']){
            $hash='';if($settings.PSObject.Properties['SHA256']){$hash=[string]$settings.SHA256}
            $status=if($hash -match '^[a-fA-F0-9]{64}$'){'CapturedEvidence'}else{'ObservedPath'}
            Add-Detail ([string]$settings.Path) $status $hash 'Location recorded by the inventory collector; this projection does not read the file.'
        }
        if($settings.PSObject.Properties['ConfigurationFile']){Add-Detail ([string]$settings.ConfigurationFile) 'ConfigurationEvidence' '' 'Configuration location recorded by the collector; this does not imply the whole file will be restored.'}
        $resolution=Get-WsmItemPathResolutionView $Item
        if($null -ne $resolution){
            if($resolution.unresolved){Add-Detail ([string]$resolution.original) 'ManualDisposition' '' ([string]$resolution.nextStep) $resolution}
            else{Add-Detail ([string]$resolution.resolved) 'ScopeNotEnumerated' '' 'Candidate location only; descendants have not been enumerated or approved.' $resolution}
        }elseif($settings.PSObject.Properties['ResolvedCandidate'] -and $settings.ResolvedCandidate){Add-Detail ([string]$settings.ResolvedCandidate) 'ScopeNotEnumerated' '' 'Candidate location only; descendants have not been enumerated or approved.'}
    }
    if($Item.PSObject.Properties['MigrationSpec'] -and $Item.MigrationSpec -and $Item.MigrationSpec.Adapter -ceq 'FileScope'){
        $spec=$Item.MigrationSpec
        if($spec.PSObject.Properties['ConfigFiles']){foreach($file in @($spec.ConfigFiles)){
            $path=[string]$file.RelativePath;$hash='';if($file.PSObject.Properties['SHA256']){$hash=[string]$file.SHA256}
            Add-Detail $path 'ReviewedExactFile' $hash 'Exact file recorded in the reviewed migration specification; live content is revalidated by export.'
        }}
        if($spec.PSObject.Properties['ContentSelection'] -and [string]$spec.ContentSelection -ceq 'ExactMembers' -and $spec.PSObject.Properties['Members']){foreach($member in @($spec.Members)){if($member.PSObject.Properties['EntryType'] -and [string]$member.EntryType -ceq 'Directory'){Add-Detail ([string]$member.RelativePath) 'ReviewedExactDirectory' '' 'Reviewed empty directory member; it is recreated at its original location, contents added later are not included.'}else{Add-Detail ([string]$member.RelativePath) 'ReviewedExactMember' ([string]$member.SHA256) 'Hash-bound file member only; sibling files and directory contents are not included.'}}}
        if(-not $rows.Count){Add-Detail ([string]$spec.SourcePath) 'ScopeNotEnumerated' '' 'Reviewed source scope; a bounded file listing is a separate read-only operation.'}
    }
    $rows.ToArray()
}

function Assert-WsmWizardDetailLocalPath([string]$Path) {
    if($Path -notmatch '^[A-Za-z]:\\' -or $Path -match '^(?:\\\\|\\\?\\|\\\.\\)' -or $Path.Substring(2).Contains(':')){throw 'File details require an absolute local drive path.'}
    $full=[IO.Path]::GetFullPath($Path)
    foreach($segment in @($full.Substring(3).Replace('/','\').Split('\'))){
        if($segment.TrimEnd(' ','.') -match '^(?i:CON|PRN|AUX|NUL|CLOCK\$|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)'){throw 'File details do not use reserved Windows device names.'}
    }
    $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($full))
    if($drive.DriveType -ne [IO.DriveType]::Fixed){throw 'File details do not follow network or removable drives.'}
    # Check from the drive down, before any child lookup can follow a junction.
    $cursor=[IO.Path]::GetPathRoot($full)
    foreach($part in @('')+@($full.Substring($cursor.Length).Split('\')|Where-Object {$_})){
        if($part){$cursor=Join-Path $cursor $part}
        try{$attributes=[IO.File]::GetAttributes($cursor)}catch [IO.FileNotFoundException]{break}catch [IO.DirectoryNotFoundException]{break}
        if(($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'File details do not follow reparse ancestors.'}
    }
    $full
}

function Export-WsmWizardFileDetails {
    [CmdletBinding()]param([Parameter(Mandatory)]$Item,[Parameter(Mandatory)][string]$OutputDirectory,[string[]]$ExcludedRoot=@(),[ValidateRange(1,10000)][int]$MaxEntries=1000,[ValidateRange(1,120)][int]$TimeoutSeconds=15,$CancellationToken=$null)
    if(-not $Item.PSObject.Properties['MigrationSpec'] -or -not $Item.MigrationSpec -or $Item.MigrationSpec.Adapter -cne 'FileScope'){throw 'Choose a reviewed file scope before listing its contents.'}
    $spec=$Item.MigrationSpec;$source=Assert-WsmWizardDetailLocalPath ([string]$spec.SourcePath)
    $output=Assert-WsmWizardDetailLocalPath $OutputDirectory
    $forbidden=@($output)+@($ExcludedRoot|ForEach-Object {Assert-WsmWizardDetailLocalPath $_})
    foreach($other in $forbidden){if(Test-WsmPathOverlap (Get-WsmPhysicalPath $source) (Get-WsmPhysicalPath $other)){throw 'File detail source overlaps a controlled tool or output directory.'}}
    if(-not [IO.File]::Exists($source) -and -not [IO.Directory]::Exists($source)){throw 'File detail source is unavailable.'}
    $rows=New-Object 'System.Collections.Generic.List[object]';$gaps=New-Object 'System.Collections.Generic.List[object]'
    $stack=New-Object 'System.Collections.Generic.Stack[string]';$stack.Push($source)
    $watch=[Diagnostics.Stopwatch]::StartNew();$status='Complete'
    while($stack.Count){
        Assert-WsmCancellationBoundary $CancellationToken 'WizardFileDetailListing'
        if($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds -or $rows.Count -ge $MaxEntries){$status='Partial';$gaps.Add([pscustomobject]@{reason='ListingBudgetExceeded';pendingEntries=$stack.Count});break}
        $path=$stack.Pop();$relative=$path.Substring($source.Length).TrimStart('\');$excluded=$false
        foreach($entry in @($spec.ExcludedRelativePaths)){if($relative -ieq $entry -or $relative.StartsWith(([string]$entry).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){$excluded=$true;break}}
        if($excluded){continue}
        if($spec.PSObject.Properties['ContentSelection'] -and [string]$spec.ContentSelection -ceq 'ExactMembers'){
            if($relative){continue}
            if(-not $spec.PSObject.Properties['Members'] -or @($spec.Members).Count -eq 0){throw 'ExactMembers file details require the nonempty sealed member allowlist.'}
            $attempts=0
            foreach($member in @($spec.Members)){
                Assert-WsmCancellationBoundary $CancellationToken 'WizardExactMemberDetail'
                if($attempts -ge $MaxEntries -or $watch.Elapsed.TotalSeconds -ge $TimeoutSeconds){$status='Partial';$gaps.Add([pscustomobject]@{reason='ListingBudgetExceeded';pendingEntries=1});break};$attempts++
                $memberRelative=[string]$member.RelativePath;Assert-WsmRelativePath $memberRelative;$exact=Join-Path $source $memberRelative
                try{[void](Assert-WsmWizardDetailLocalPath $exact);if($member.PSObject.Properties['EntryType'] -and [string]$member.EntryType -ceq 'Directory'){$dirInfo=New-Object IO.DirectoryInfo($exact);if(-not $dirInfo.Exists){throw 'Exact directory member is unavailable.'};if($rows.Count -ge $MaxEntries){$status='Partial';$gaps.Add([pscustomobject]@{reason='ListingBudgetExceeded';pendingEntries=1});break};$rows.Add([pscustomobject]@{path=$memberRelative;directory=$true;bytes=[long]0;lastWriteUtc=$dirInfo.LastWriteTimeUtc.ToString('o');status='ObservedMetadata';approvedSha256='';contentRead=$false});continue};$info=New-Object IO.FileInfo($exact);if(-not $info.Exists){throw 'Exact member is unavailable.'};if($rows.Count -ge $MaxEntries){$status='Partial';$gaps.Add([pscustomobject]@{reason='ListingBudgetExceeded';pendingEntries=1});break};$rows.Add([pscustomobject]@{path=$memberRelative;directory=$false;bytes=[long]$info.Length;lastWriteUtc=$info.LastWriteTimeUtc.ToString('o');status='ObservedMetadata';approvedSha256=[string]$member.SHA256;contentRead=$false})}catch{$status='Partial';$gaps.Add([pscustomobject]@{path=$memberRelative;reason='UnavailableOrUnsafe';errorType=$_.Exception.GetType().FullName})}
            }
            break
        }
        if($spec.PSObject.Properties['ContentSelection'] -and $spec.ContentSelection -ceq 'ExactFiles'){
            if($relative){continue}
            $attempts=0
            foreach($file in @($spec.ConfigFiles)){
                Assert-WsmCancellationBoundary $CancellationToken 'WizardExactFileDetail'
                if($attempts -ge $MaxEntries -or $watch.Elapsed.TotalSeconds -ge $TimeoutSeconds){$status='Partial';$gaps.Add([pscustomobject]@{reason='ListingBudgetExceeded';pendingEntries=1});break};$attempts++
                Assert-WsmRelativePath ([string]$file.RelativePath) -AllowRoot
                $exact=if($file.RelativePath){Join-Path $source ([string]$file.RelativePath)}else{$source}
                try{[void](Assert-WsmWizardDetailLocalPath $exact);$info=New-Object IO.FileInfo($exact);if(-not $info.Exists){throw 'Exact file is unavailable.'};if($rows.Count -ge $MaxEntries){$status='Partial';$gaps.Add([pscustomobject]@{reason='ListingBudgetExceeded';pendingEntries=1});break};$rows.Add([pscustomobject]@{path=[string]$file.RelativePath;directory=$false;bytes=[long]$info.Length;lastWriteUtc=$info.LastWriteTimeUtc.ToString('o');status='ObservedMetadata';contentRead=$false})}catch{$status='Partial';$gaps.Add([pscustomobject]@{path=[string]$file.RelativePath;reason='UnavailableOrUnsafe';errorType=$_.Exception.GetType().FullName})}
            }
            break
        }
        try{
            [void](Assert-WsmWizardDetailLocalPath $path);$attributes=[IO.File]::GetAttributes($path);$directory=($attributes -band [IO.FileAttributes]::Directory) -ne 0
            $info=if($directory){New-Object IO.DirectoryInfo($path)}else{New-Object IO.FileInfo($path)}
            $rows.Add([pscustomobject]@{path=$relative;directory=$directory;bytes=$(if($directory){$null}else{[long]$info.Length});lastWriteUtc=$info.LastWriteTimeUtc.ToString('o');status='ObservedMetadata';contentRead=$false})
            if($directory){
                $iterator=[IO.Directory]::EnumerateFileSystemEntries($path).GetEnumerator()
                try{while($iterator.MoveNext()){
                    Assert-WsmCancellationBoundary $CancellationToken 'WizardFileDetailChild'
                    if($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds -or ($stack.Count+$rows.Count) -ge $MaxEntries){$status='Partial';$gaps.Add([pscustomobject]@{path=$relative;reason='ListingBudgetExceeded';pendingEntries=1});break}
                    $stack.Push([string]$iterator.Current)
                }}finally{if($iterator -is [IDisposable]){$iterator.Dispose()}}
            }
        }catch{if($_.Exception -is [OperationCanceledException]){throw};$status='Partial';$gaps.Add([pscustomobject]@{path=$relative;reason='UnavailableOrUnsafe';errorType=$_.Exception.GetType().FullName})}
    }
    [void](Assert-WsmWizardDetailLocalPath $output)
    if(-not [IO.Directory]::Exists($output)){[void][IO.Directory]::CreateDirectory($output);Protect-WsmDirectory $output}
    $record=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='WizardFileDetails';ItemId=[string]$Item.ItemId;SourcePath=$source;SpecHash=(Get-WsmHashText ($spec|ConvertTo-Json -Depth 30 -Compress));Status=$status;CapturedUtc=(Get-WsmUtc);ContentRead=$false;BackupVerified=$false;Entries=@($rows.ToArray());Gaps=@($gaps.ToArray())}
    $path=Join-Path $output ('file-details-'+[Guid]::NewGuid().ToString('N')+'.json');Write-WsmJson $path $record
    [pscustomobject]@{Status=$status;ItemId=[string]$Item.ItemId;SpecHash=$record.SpecHash;Path=$path;SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();EntryCount=$rows.Count;GapCount=$gaps.Count;ContentRead=$false;BackupVerified=$false}
}

function Read-WsmWizardFileDetails([string]$Path,[string]$ExpectedHash,[string]$OwnedRoot,$Item) {
    if($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'File details require the recorded SHA256.'}
    $root=(Assert-WsmWizardDetailLocalPath $OwnedRoot).TrimEnd('\')+'\';$full=Assert-WsmWizardDetailLocalPath $Path
    if(-not $full.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw 'File details are outside their controlled directory.'}
    $info=New-Object IO.FileInfo($full);if(-not $info.Exists -or $info.Length -gt 8MB){throw 'File detail record is missing or exceeds its read budget.'}
    if((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash -ine $ExpectedHash){throw 'File detail record changed.'}
    $record=Read-WsmJson $full;Assert-WsmEnvelope $record 'WizardFileDetails'
    if($record.SchemaVersion -ne 1 -or $record.ItemId -cne [string]$Item.ItemId -or $record.SpecHash -ine (Get-WsmHashText ($Item.MigrationSpec|ConvertTo-Json -Depth 30 -Compress)) -or $record.SourcePath -ine [IO.Path]::GetFullPath([string]$Item.MigrationSpec.SourcePath) -or $record.ContentRead -or $record.BackupVerified -or $record.Status -notin @('Complete','Partial') -or @($record.Entries).Count -gt 10000){throw 'File details do not match the current reviewed scope.'}
    $record
}
