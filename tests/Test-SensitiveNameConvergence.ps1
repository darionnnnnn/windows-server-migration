#requires -Version 5.1
# A3（PLAN 17.123）：R18 進度文字安全化、S6 DeveloperProbe 遮蔽三縫、S11 敏感名稱單一判定＋靜態守門。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:passed=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:passed++}
function InModule([scriptblock]$Block,[object[]]$Arguments=@()){& $module $Block @Arguments}

# ---------------------------------------------------------------- S11：名稱判定表（正例與反例）
$masked=@('Passwords','Tokens','private_key','passwd','pwd','clientsecret','authtoken','DB_PASSWORD','db-password','ServicePassword','api-key','ApiKey','APIKey','connection_string','ConnectionStrings','PrivateKey','client_secret','AccessToken','db_pwd','dbtoken','MySecret','Credentials','Password2','token1','XMLConfig','Command','Arguments','SDDL','Wallet','Authorization','sharedaccesskey','dbpasswordhash')
$notMasked=@('Description','description_text','Transcript','Transcription','tokenizer','Tokenizer','TokenizerName','Subscription','Name','ItemId','Keyboard','Passenger','Compass','Status','Path','Owner','Reason','FileCount','')
foreach($name in $masked){Check ([bool](InModule {param($n) Test-WsmSensitiveName $n} @($name))) ('Sensitive name was not recognised: '+$name)}
foreach($name in $notMasked){Check (-not [bool](InModule {param($n) Test-WsmSensitiveName $n} @($name))) ('Harmless name was classified as sensitive: '+$name)}
Check (-not [bool](InModule {Test-WsmSensitiveName $null})) 'A null name was classified as sensitive.'
# Main agent (A3 review): token anywhere in a name except tokeniz*, and Unicode format characters (Cf) never hide a secret name or value.
foreach($name in @('tokenvalue','TokenSecret','mytokenstore')){Check ([bool](InModule {param($n) Test-WsmSensitiveName $n} @($name))) ('Sensitive name was not recognised: '+$name)}
foreach($name in @('tokenize','Tokenization')){Check (-not [bool](InModule {param($n) Test-WsmSensitiveName $n} @($name))) ('Harmless name was classified as sensitive: '+$name)}
$zwsp=[string][char]0x200B;$rlo=[string][char]0x202E
foreach($name in @(('Pass'+$zwsp+'word'),('to'+$rlo+'ken'),('Api'+[char]0x2060+'Key'))){Check ([bool](InModule {param($n) Test-WsmSensitiveName $n} @($name))) 'A format character inside a secret name hid it from the name check.'}
$hidden='pass'+$zwsp+'word=hunter2-value'
Check ([bool](InModule {param($t) Test-WsmSensitiveAssignmentText $t} @($hidden))) 'A format character inside an embedded assignment hid it from the assignment check.'
$protected=[string](InModule {param($t) Protect-WsmSensitiveAssignmentText $t} @($hidden))
Check ($protected -notmatch 'hunter2') ('A format character inside an embedded assignment leaked its value: '+$protected)
$displayed=[string](InModule {param($t) ConvertTo-WsmPathDisplayText $t} @($hidden))
Check ($displayed -notmatch 'hunter2') ('The display text leaked a value hidden behind a format character: '+$displayed)
Check ([bool](InModule {param($t) Test-WsmSensitivePointerText $t} @(("/system.web/identity/@pass"+$zwsp+"word=")))) 'A format character inside an IIS pointer hid the secret field.'
Check ([string](InModule {param($t) Protect-WsmSensitiveAssignmentText $t} @(('a'+$zwsp+'b status=ok'))) -ceq ('a'+$zwsp+'b status=ok')) 'Text without a secret assignment must keep its format characters for the visible marker.'

# 純量分支與物件分支共用同一判定：同一個名稱，兩邊的結果必須一致，且等於分類函式的答案。
foreach($name in @($masked+$notMasked | Where-Object {$_})){
    $expected=[bool](InModule {param($n) Test-WsmSensitiveName $n} @($name))
    $scalar=InModule {param($n) ConvertTo-WsmAssistiveSafeValue 'plain-value' $n} @($name)
    $dictionary=InModule {param($n) ConvertTo-WsmAssistiveSafeValue ([ordered]@{$n='plain-value'}) 'Parent'} @($name)
    $object=InModule {param($n) $o=New-Object psobject;$o|Add-Member NoteProperty $n 'plain-value';ConvertTo-WsmAssistiveSafeValue $o 'Parent'} @($name)
    $scalarWithheld=($scalar -ne 'plain-value')
    $dictionaryWithheld=($dictionary.PSObject.Properties[$name].Value -ne 'plain-value')
    $objectWithheld=($null -eq $object.PSObject.Properties[$name]) -or ($object.PSObject.Properties[$name].Value -ne 'plain-value')
    Check ($scalarWithheld -eq $expected) ('Scalar branch disagrees with the shared classifier for '+$name)
    Check ($dictionaryWithheld -eq $expected) ('Dictionary branch disagrees with the shared classifier for '+$name)
    Check ($objectWithheld -eq $expected) ('Object branch disagrees with the shared classifier for '+$name)
}
# 無害欄位整個保留（物件分支以前會用子字串把 Description／Transcript 整個丟掉）
$kept=InModule {$o=[pscustomobject]@{Description='Fixture description';Transcript='Fixture transcript';TokenizerName='fixture-tokenizer';DB_PASSWORD='never-return-this';Tokens='never-return-tokens'};ConvertTo-WsmAssistiveSafeValue $o 'Parent'}
Check ($kept.Description -ceq 'Fixture description' -and $kept.Transcript -ceq 'Fixture transcript' -and $kept.TokenizerName -ceq 'fixture-tokenizer') 'The object branch dropped a harmless property.'
Check (-not $kept.PSObject.Properties['DB_PASSWORD'] -and -not $kept.PSObject.Properties['Tokens']) 'The object branch exposed a sensitive property.'
Check (-not (($kept|ConvertTo-Json -Depth 5) -match 'never-return')) 'A sensitive value reached the serialised object branch result.'
# 內嵌指派文字
foreach($text in @('password=abc','Passwords: abc','set token = abc123','my api_key:abc','client-secret=abc')){Check ((InModule {param($t) ConvertTo-WsmAssistiveSafeValue $t 'Note'} @($text)) -ceq '[sensitive text withheld]') ('Embedded assignment was not withheld: '+$text)}
foreach($text in @('tokenizer=abc','a transcript: ok','Fixture description for scripts')){Check ((InModule {param($t) ConvertTo-WsmAssistiveSafeValue $t 'Note'} @($text)) -ceq $text) ('Harmless text was withheld: '+$text)}

# ---------------------------------------------------------------- R18：進度文字
$invisible=[ordered]@{RLO=[char]0x202E;ZWSP=[char]0x200B;ZWNJ=[char]0x200C;ZWJ=[char]0x200D;LRM=[char]0x200E;RLM=[char]0x200F;WordJoiner=[char]0x2060;BOM=[char]0xFEFF;NEL=[char]0x0085;LineSep=[char]0x2028;ParaSep=[char]0x2029;NUL=[char]0;DEL=[char]0x7f;LF=[char]10}
foreach($entry in $invisible.GetEnumerator()){
    $char=[string]$entry.Value
    $result=InModule {param($t) ConvertTo-WsmProgressText $t} @('a'+$char+'b')
    Check (-not $result.Contains($char)) ('The progress text kept the raw '+$entry.Key+' character.')
    Check ($result -match '\\u[0-9A-F]{4}') ('The progress text did not mark the '+$entry.Key+' character visibly.')
}
$rlo=InModule {param($t) ConvertTo-WsmProgressText $t} @(('doc'+[char]0x202E+'txt.exe'))
Check ($rlo -ceq 'doc\u202Etxt.exe') 'The RTL override was not rendered as a visible marker.'
$marker='…（已截斷）'
$long=('x'*300)
$truncated=InModule {param($t) ConvertTo-WsmProgressText $t} @($long)
Check ($truncated.EndsWith($marker)) 'A truncated progress text carries no truncation marker.'
Check ($truncated.StartsWith('x'*256) -and $truncated.Length -eq 256+$marker.Length) 'The truncated progress text has the wrong length.'
$again=InModule {param($t) ConvertTo-WsmProgressText $t} @($truncated)
Check ($again -ceq $truncated) 'Sanitising an already truncated progress text again is not idempotent.'
$exact=InModule {param($t) ConvertTo-WsmProgressText $t} @(('y'*256))
Check ($exact -ceq ('y'*256)) 'A progress text of exactly the limit was marked as truncated.'
foreach($plain in @('正在備份 設定檔 C:\Data\file.txt','Backing up item 3 of 10','a  b','')){Check ((InModule {param($t) ConvertTo-WsmProgressText $t} @($plain)) -ceq $plain) ('An ordinary progress text changed: '+$plain)}
Check ((InModule {ConvertTo-WsmProgressText $null}) -ceq '') 'A null progress text is not empty.'
Check ((InModule {param($t) ConvertTo-WsmProgressText $t} @('  padded  ')) -ceq 'padded') 'Progress text is not trimmed.'
Check ((InModule {param($t) ConvertTo-WsmProgressText $t} @('uploading password=hunter2 now')) -ceq 'uploading password=[redacted] now') 'An embedded secret assignment was not redacted in progress text.'
Check ((InModule {param($t) ConvertTo-WsmProgressText $t} @('Passwords: hunter2')) -ceq 'Passwords=[redacted]') 'A plural secret assignment was not redacted in progress text.'
# 與路徑顯示共用同一規則：同一輸入，兩者的可見化結果一致
$sample='a'+[char]0x202E+'b'+[char]0x200B+'c'
Check ((InModule {param($t) ConvertTo-WsmProgressText $t} @($sample)) -ceq (InModule {param($t) ConvertTo-WsmPathDisplayText $t} @($sample))) 'Progress text and path display text disagree on invisible characters.'

# ---------------------------------------------------------------- S6：DeveloperProbe
function ProbeText([string]$Text){InModule {param($t) ConvertTo-WsmDeveloperProbeSafeText $t 'a3-salt'} @($Text)}
function ProbeObject($Object){InModule {param($o) ConvertTo-WsmDeveloperProbeSafeObject -InputObject $o -Salt 'a3-salt'} @(,$Object)}
# 1. 裸 UNC
foreach($sample in @('\\fileserver01\share\data','see \\fileserver01\share\data ok','open: \\fileserver01\share\x.txt','x=1 \\10.20.30.40\admin$\y')){
    $safe=ProbeText $sample
    Check ($safe -notmatch 'fileserver01|10\.20\.30\.40|share') ('A bare UNC path leaked: '+$sample)
    Check ($safe -match '\[path-[0-9a-f]{12}\]') ('A bare UNC path was not replaced by an alias: '+$sample)
}
Check ((ProbeText 'drive C:\Windows\Temp\x') -notmatch 'Windows') 'A drive path stopped being aliased.'
Check ((ProbeText 'mode=fast status=ok') -ceq 'mode=fast status=ok') 'Ordinary text was altered.'
Check ((ProbeText 'a\\b is not a path') -ceq 'a\\b is not a path') 'A double backslash inside a word was treated as a UNC path.'
# 2. 名稱與值分在兩個欄位
foreach($shape in @('hashtable','object','array-of-rows')){
    $row=[ordered]@{Name='DB_PASSWORD';Value='hunter2-VALUE'}
    $probeInput=switch($shape){'hashtable'{$row}'object'{[pscustomobject]$row}default{@([pscustomobject]$row,[pscustomobject][ordered]@{Name='Mode';Value='fast'})}}
    $json=(ProbeObject $probeInput)|ConvertTo-Json -Depth 8
    Check ($json -notmatch 'hunter2') ('The value of a secret Name/Value pair leaked ('+$shape+').')
    Check ($json -match 'DB_PASSWORD') ('The secret name itself should stay readable ('+$shape+').')
    if($shape -ceq 'array-of-rows'){Check ($json -match 'fast') 'A harmless Name/Value pair was over-redacted.'}
}
$other=(ProbeObject ([pscustomobject][ordered]@{Name='Description';Value='fixture-text'}))|ConvertTo-Json
Check ($other -match 'fixture-text') 'A harmless Description pair was redacted.'
$tokenizer=(ProbeObject ([pscustomobject][ordered]@{Key='tokenizer';Data='fixture-data'}))|ConvertTo-Json
Check ($tokenizer -match 'fixture-data') 'A tokenizer pair was redacted.'
$keyed=(ProbeObject ([pscustomobject][ordered]@{SettingName='ClientSecret';Value='hunter2-VALUE'}))|ConvertTo-Json
Check ($keyed -notmatch 'hunter2') 'A SettingName/Value pair leaked.'
$textPair=ProbeText "{Name='DB_PASSWORD';Value='hunter2-VALUE'}"
Check ($textPair -notmatch 'hunter2' -and $textPair -match 'DB_PASSWORD') 'A stringified Name/Value pair leaked.'
Check ((ProbeText "{Name='Mode';Value='fast'}") -ceq "{Name='Mode';Value='fast'}") 'A harmless stringified pair was redacted.'
# 3. Account／Domain
$identity=(ProbeObject ([pscustomobject][ordered]@{Account='CORP\svc-fixture';Domain='CORP-FIXTURE';Status='ok'}))
$identityJson=$identity|ConvertTo-Json -Depth 8
Check ($identityJson -notmatch 'svc-fixture|CORP-FIXTURE') 'Account or Domain leaked.'
Check ($identity.Status -ceq 'ok') 'A harmless Status field was redacted.'
$identityDict=(ProbeObject ([ordered]@{Account='CORP\svc-fixture';Domain='CORP-FIXTURE'}))|ConvertTo-Json -Depth 8
Check ($identityDict -notmatch 'svc-fixture|CORP-FIXTURE') 'Account or Domain leaked from a dictionary.'
# 既有欄位仍遮蔽、密碼類名稱改走單一判定
$secretProps=(ProbeObject ([pscustomobject][ordered]@{Passwords='hunter2-VALUE';private_key='hunter2-KEY';clientsecret='hunter2-SECRET';Tokenizer='fixture-tokenizer'}))
Check (($secretProps|ConvertTo-Json -Depth 8) -notmatch 'hunter2') 'A sensitive property name leaked through the probe.'
Check (@($secretProps.PSObject.Properties).Count -eq 4 -and (($secretProps|ConvertTo-Json) -match 'fixture-tokenizer')) 'The probe over-redacted tokenizer.'

# ---------------------------------------------------------------- 靜態守門：祕密名稱 regex 只能在共用函式內
$allowedFunctions=@('Test-WsmSensitiveName','Get-WsmSensitiveAssignmentNameRegex','Test-WsmSensitivePointerText')
# 範圍外（不在 A3 白名單）尚未收斂的檔案；每一項都要在後續批次改成呼叫共用函式後從清單移除。
$deferredFiles=@(
    # 真的有自己的祕密名稱／指派 regex，等後續批次改呼叫 Test-WsmSensitiveName／Protect-WsmSensitiveAssignmentText
    'AssistiveReports.ps1','Cutover.ps1','EnterpriseDiscovery.ps1','EnvironmentConfirmation.ps1','Fleet.ps1','GeneralHostContracts.ps1','HtmlConsole.ps1','MigrationContracts.ps1','OracleClientContracts.ps1','Reports.ps1','SettingTransitions.ps1','SoftwareInventory.ps1','WindowsSettingsReview.ps1','WizardHtmlRuntime.ps1','WorkloadDiscovery.ps1'
    # 含祕密字樣但不是名稱分類（路由、原生程式碼、registry／XML 結構判斷等），之後逐一確認是否可免列
    'Adapters.ps1','Inventory.ps1','OperationRequests.ps1','ServiceIdentity.ps1','ServiceSupplement.ps1','WorkspaceTransfer.ps1'
)
$keyword='(?i)password|passwd|pwd|secret|token|api[-_]?key|private[ _.?-]*key|credential|connection[-_]?string'
$metachar='\(\?|\\s|\||\\b|\['
function Get-FlaggedStrings([string]$Path){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ('Parse errors: '+$Path)}
    $functions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
    $found=New-Object 'System.Collections.Generic.List[string]'
    foreach($node in @($ast.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst]},$true))){
        $value=$node.Value
        if($value -notmatch $keyword -or $value -notmatch $metachar -or $value -match '-----BEGIN'){continue}
        $line=$node.Extent.StartLineNumber
        $owner=$functions | Where-Object {$_.Extent.StartLineNumber -le $line -and $_.Extent.EndLineNumber -ge $line} | Sort-Object {$_.Extent.EndLineNumber-$_.Extent.StartLineNumber} | Select-Object -First 1
        $ownerName=$(if($owner){$owner.Name}else{''})
        if($allowedFunctions -contains $ownerName){continue}
        $found.Add(($line.ToString()+':'+$ownerName))
    }
    $found.ToArray()
}
$srcFiles=@(Get-ChildItem (Join-Path $repo 'src') -File -Filter '*.ps1')
$unexpected=New-Object 'System.Collections.Generic.List[string]'
$stillFlagged=@{}
foreach($file in $srcFiles){
    $hits=@(Get-FlaggedStrings $file.FullName)
    if(-not $hits.Count){continue}
    if($deferredFiles -contains $file.Name){$stillFlagged[$file.Name]=$true;continue}
    $unexpected.Add($file.Name+' '+($hits -join ','))
}
Check ($unexpected.Count -eq 0) ('A secret-name regex was written outside the shared classifier: '+($unexpected -join '; '))
foreach($name in $deferredFiles){Check ($stillFlagged.ContainsKey($name)) ('The deferred-file list is stale; remove '+$name+' because it no longer holds a secret-name regex.')}
# 共用函式存在，且四個消費端都呼叫它
$coreText=[IO.File]::ReadAllText((Join-Path $repo 'src\Core.ps1'))
foreach($function in $allowedFunctions){Check ($coreText -match ('function '+[regex]::Escape($function)+'\b')) ('The shared function is missing: '+$function)}
function SrcText([string]$Name){[IO.File]::ReadAllText((Join-Path $repo ('src\'+$Name)))}
$forms=SrcText 'AssistiveReviewForms.ps1';$probe=SrcText 'DeveloperProbe.ps1';$details=SrcText 'WizardDetails.ps1';$projection=SrcText 'WizardBackupProjection.ps1'
Check (([regex]::Matches($forms,'Test-WsmSensitiveName')).Count -ge 2) 'AssistiveReviewForms does not call the shared name classifier from both branches.'
Check ($probe -match 'Test-WsmSensitiveName') 'DeveloperProbe does not call the shared name classifier.'
Check ($details -match 'Protect-WsmSensitiveAssignmentText') 'WizardDetails does not call the shared assignment redactor.'
$progressBody=[regex]::Match($projection,'(?s)function ConvertTo-WsmProgressText.*?\r?\n\}').Value
Check ($progressBody -match 'ConvertTo-WsmBackupSafePathText') 'ConvertTo-WsmProgressText does not reuse the single sanitising rule.'
Check ($progressBody -notmatch '\[regex\]|-replace') 'ConvertTo-WsmProgressText carries its own regex again.'
Write-Host ('PASS: sensitive-name convergence, progress text sanitising and developer-probe redaction ('+$script:passed+' checks).')
