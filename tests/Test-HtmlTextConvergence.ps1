#requires -Version 5.1
# R26-1c（PLAN 17.131）：離線報告的 ConvertTo-WsmHtmlText 與 Assistive 報告的 ConvertTo-WsmAssistiveReportText 是同一份實作（遮蔽＋HtmlEncode）。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$script:checks=0
function Check([bool]$Condition,[string]$Message){$script:checks++;if(-not $Condition){throw $Message}}

$values=@($null,'','plain','<b>&"x"</b>',"it's",'C:\Program Files\App\a.exe','中文 <標籤>','Tokenizer=abc','password=hunter2','Password: hunter2','my secret = abc','api token:abc123','credential=x','PRIVATE KEY: -----BEGIN','pwd=1')
foreach($value in $values){
    $a=& $module {param($v) ConvertTo-WsmHtmlText $v} $value
    $b=& $module {param($v) ConvertTo-WsmAssistiveReportText $v} $value
    Check ([string]$a -ceq [string]$b) ('The two HTML text functions disagree for: '+[string]$value)
}
# 兩邊都遮蔽
foreach($secret in @('password=hunter2','Password: hunter2','my secret = abc','api token:abc123','credential=x','pwd=1')){
    $out=[string](& $module {param($v) ConvertTo-WsmHtmlText $v} $secret)
    Check ($out -notmatch 'hunter2|abc123|=x$|=1$|= abc') ('The offline report text leaked: '+$secret+' -> '+$out)
    Check ($out -ceq '[sensitive value withheld]') ('A withheld value must use the shared marker: '+$out)
}
# 上游已經把值換成 [redacted] 的文字不再整段遮蔽（否則備註裡的無害說明會跟著消失）；同一段文字裡另有真正的指派仍然整段遮蔽
Check ([string](& $module {ConvertTo-WsmHtmlText 'license note 3 password=[redacted]'}) -ceq 'license note 3 password=[redacted]') 'An already redacted assignment must stay readable.'
Check ([string](& $module {ConvertTo-WsmHtmlText 'password=[redacted] secret=abc'}) -ceq '[sensitive value withheld]') 'A real assignment next to a redacted one must still be withheld.'
# Main agent: a value that only starts with the literal [redacted] is not an upstream redaction; it must still be withheld.
Check ([string](& $module {ConvertTo-WsmHtmlText 'password=[redacted]realSecret'}) -ceq '[sensitive value withheld]') 'A value glued to a literal [redacted] prefix leaked.'
Check ([string](& $module {ConvertTo-WsmHtmlText 'token: [redacted];next'}) -ceq 'token: [redacted];next') 'A redacted value followed by a separator must stay readable.'
Check ([string](& $module {ConvertTo-WsmHtmlText '原因：password=[redacted]；負責人：x'}) -ceq [Net.WebUtility]::HtmlEncode('原因：password=[redacted]；負責人：x')) 'A redacted value followed by a full-width separator must stay readable.'
Check ([string](& $module {ConvertTo-WsmHtmlText 'password=[redacted]-secret'}) -ceq '[sensitive value withheld]') 'A value continuing after a literal [redacted] leaked.'
Check ([string](& $module {ConvertTo-WsmHtmlText 'password=[redacted]\secret'}) -ceq '[sensitive value withheld]') 'A value continuing with a backslash after a literal [redacted] leaked.'
Check ([string](& $module {ConvertTo-WsmHtmlText 'password= [Redacted]'}) -ceq 'password= [Redacted]') 'The redaction marker is matched without regard to spacing and case.'
# 無害文字照常跳脫
Check ([string](& $module {ConvertTo-WsmHtmlText '<b>&"x"</b>'}) -ceq '&lt;b&gt;&amp;&quot;x&quot;&lt;/b&gt;') 'Harmless text must only be HTML-encoded.'
Check ([string](& $module {ConvertTo-WsmHtmlText 'Tokenizer=abc'}) -ceq 'Tokenizer=abc') 'A harmless assignment must stay readable.'
Check ([string](& $module {ConvertTo-WsmHtmlText $null}) -ceq '') 'Null must stay empty.'
# 靜態：薄包裝不得自己呼叫 HtmlEncode，也不得再寫一份遮蔽 regex
$path=Join-Path $PSScriptRoot '..\src\WizardBackupProjection.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
$function=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'ConvertTo-WsmHtmlText'},$true)
Check ($null -ne $function) 'ConvertTo-WsmHtmlText was not found.'
$body=$function.Body.Extent.Text
Check ($body -notmatch 'HtmlEncode' -and $body -notmatch 'password') 'ConvertTo-WsmHtmlText must delegate instead of owning an encoder or a masking rule.'
Check ($body -match 'ConvertTo-WsmAssistiveReportText') 'ConvertTo-WsmHtmlText must call the shared implementation.'
Write-Host ('PASS: Test-HtmlTextConvergence offline report and Assistive report share one masked HTML encoder ('+$script:checks+' checks).')
