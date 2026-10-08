function Get-WsmFailureDetails($Failure) {
    $error=$Failure;if($Failure -is [Management.Automation.ErrorRecord]){$error=$Failure.Exception}
    if($error -isnot [Exception]){throw 'Failure details require an Exception or ErrorRecord.'}
    $category='OperationFailure';$code=$null;$nativeTool='';$cursor=$error;$hint='保留操作目錄與日誌，確認實際狀態後再預覽／重試。'
    while($cursor){
        if($cursor.Data.Contains('NativeCode')){$code=$cursor.Data['NativeCode']};if($cursor.Data.Contains('NativeTool')){$nativeTool=$cursor.Data['NativeTool']}
        if($cursor -is [TimeoutException]){$category='Timeout';$hint='作業已超時；先確認是否已產生副作用，使用修復檢查點，不直接重複執行。'}
        elseif($cursor -is [UnauthorizedAccessException]){$category='Permission';$hint='使用核准的系統管理權限，檢查資料、金鑰及系統 API 權限；不要放寬整個目錄的 ACL。'}
        elseif($cursor -is [IO.InvalidDataException] -or $cursor -is [Management.Automation.ParameterBindingException]){$category='InputValidation';$hint='重新取得目前計畫／版本與獨立可信摘要，修正契約欄位後再預覽。'}
        elseif($cursor -is [ComponentModel.Win32Exception]){$code=$cursor.NativeErrorCode}
        elseif($cursor -is [IO.IOException]){$ioCode=$cursor.HResult -band 65535;if($ioCode -in @(32,33)){$category='FileLocked';$hint='確認已停寫及檔案使用者，於維護窗重新匯出；不要略過被鎖住的檔案。'}elseif($ioCode -eq 112){$category='Capacity';$hint='補足所列工作目錄與目標磁碟容量，保留已封存分卷，重新預檢。'}}
        $cursor=$cursor.InnerException
    }
    if($null -ne $code){switch([int]$code){5{$category='Permission';$hint='原生 API 拒絕存取；檢查核准的權限及物件 ACL。'}32{$category='FileLocked';$hint='原生 API 遇到檔案鎖；確認停寫及持有者後重試。'}112{$category='Capacity';$hint='磁碟空間不足；補足空間並重新預檢，勿刪除回退資料。'}1053{$category='Timeout';$hint='服務未及時回應；先檢查 binary、帳號、相依及服務日誌。'}1060{$category='ObjectMissing';$hint='原生 API 查無物件；檢查映射名稱及套用狀態，不能直接當作成功。'}1072{$category='PendingDeletion';$hint='服務已標記刪除；關閉持有者並重新確認物件状态，必要重開機另安排。'}}}
    [pscustomobject]@{Category=$category;NativeCode=$code;NativeTool=$nativeTool;Hint=$hint;AutomaticRetrySafe=$false;RawOutputIncluded=$false}
}
function New-WsmNativeFailure([string]$Tool,[int]$Code,[string]$Operation) {
    $error=New-Object InvalidOperationException(($Operation+' failed; '+$Tool+' native code '+$Code));$error.Data['NativeCode']=$Code;$error.Data['NativeTool']=$Tool;$error
}
