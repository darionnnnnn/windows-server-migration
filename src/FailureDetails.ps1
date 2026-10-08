function Get-WsmFailureDetails($Failure) {
    $error=$Failure;if($Failure -is [Management.Automation.ErrorRecord]){$error=$Failure.Exception}
    if($error -isnot [Exception]){throw 'Failure details require an Exception or ErrorRecord.'}
    $category='OperationFailure';$code=$null;$nativeTool='';$nativeResult='';$hresult=$null;$cursor=$error;$cancelFailure=$null;$nativeDiagnostics=@{};$hint='保留操作目錄與日誌，確認實際狀態後再預覽／重試。'
    while($cursor){
        if($cursor -is [OperationCanceledException] -and $cursor.Data['CancellationRequested']){$cancelFailure=$cursor}
        foreach($field in @('NativeProcessId','ProcessKillAttempted','ProcessExitObserved','ProcessKillVerified','ChildProcessTerminationVerified','TerminationScope','ProcessExitCode','StdOutCaptureComplete','StdErrCaptureComplete','StdOutCaptureSucceeded','StdErrCaptureSucceeded','StdOutCharacters','StdErrCharacters','StdOutUtf8Bytes','StdErrUtf8Bytes','StdOutSha256','StdErrSha256','StdOutTruncated','StdErrTruncated')){
            if($cursor.Data.Contains($field)){$value=$cursor.Data[$field];if($value -is [bool] -or $value -is [int] -or $value -is [long] -or ($field -like '*Sha256' -and [string]$value -match '^[a-f0-9]{64}$') -or ($field -ceq 'TerminationScope' -and [string]$value -ceq 'OwnedProcessOnly')){$nativeDiagnostics[$field]=$value}}
        }
        if($cursor.Data.Contains('NativeCode')){$code=$cursor.Data['NativeCode']};if($cursor.Data.Contains('NativeTool')){$nativeTool=$cursor.Data['NativeTool']}
        if($cursor.Data.Contains('NativeResult')){$nativeResult=[string]$cursor.Data['NativeResult']}
        if($cursor.HResult -ne 0){$hresult=('0x{0:X8}' -f $cursor.HResult);if(($cursor.HResult -band -65536) -eq -2147024896 -and $null -eq $code){$code=$cursor.HResult -band 65535}}
        if($cursor -is [OperationCanceledException]){$category='Cancelled';$hint='已在安全邊界取消；保留日誌與已完成的資料塊，核對尚待修復的意圖後再以新操作代號重試。'}
        elseif($cursor -is [TimeoutException]){$category='Timeout';$hint='作業已超時；先確認是否已產生副作用，使用修復檢查點，不直接重複執行。'}
        elseif($cursor -is [UnauthorizedAccessException]){$category='Permission';$hint='使用核准的系統管理權限，檢查資料、金鑰及系統 API 權限；不要放寬整個目錄的 ACL。'}
        elseif($cursor -is [IO.InvalidDataException] -or $cursor -is [Management.Automation.ParameterBindingException]){$category='InputValidation';$hint='重新取得目前計畫／版本與獨立可信摘要，修正契約欄位後再預覽。'}
        elseif($cursor -is [ComponentModel.Win32Exception]){$code=$cursor.NativeErrorCode}
        elseif($cursor -is [IO.IOException]){$ioCode=$cursor.HResult -band 65535;if($ioCode -in @(32,33)){$category='FileLocked';$hint='確認已停寫及檔案使用者，於維護窗重新匯出；不要略過被鎖住的檔案。'}elseif($ioCode -eq 112){$category='Capacity';$hint='補足所列工作目錄與目標磁碟容量，保留已封存分卷，重新預檢。'}}
        $cursor=$cursor.InnerException
    }
    if($cancelFailure){$details=Get-WsmCancellationFailureDetails $cancelFailure;$details | Add-Member NoteProperty NativeDiagnostics ([pscustomobject]$nativeDiagnostics) -Force;return $details}
    if($null -ne $code){switch([int]$code){5{$category='Permission';$hint='原生 API 拒絕存取；檢查核准的權限及物件 ACL。'}32{$category='FileLocked';$hint='原生 API 遇到檔案鎖；確認停寫及持有者後重試。'}112{$category='Capacity';$hint='磁碟空間不足；補足空間並重新預檢，勿刪除回退資料。'}1053{$category='Timeout';$hint='服務未及時回應；先檢查 binary、帳號、相依及服務日誌。'}1060{$category='ObjectMissing';$hint='原生 API 查無物件；檢查映射名稱及套用狀態，不能直接當作成功。'}1072{$category='PendingDeletion';$hint='服務已標記刪除；關閉持有者並重新確認物件状态，必要重開機另安排。'}}}
    if($null -ne $code){switch([int]$code){
        1058 {$category='Disabled';$hint='服務停用或裝置未啟用；核對已審核 staging／final 政策，不能直接開啟未批准的服務。'}
        1059 {$category='DependencyCycle';$hint='服務相依存在循環；重新審核 service／load-order group 相依，使用群組專用協調。'}
        1061 {$category='OperationInProgress';$hint='服務暫時不能接受控制；檢查 pending 狀態與日誌，確認既有操作結果後再修復。'}
        1067 {$category='ProcessAborted';$hint='服務程序意外終止；檢查服務與應用日誌、binary、runtime 和權限，保留已產生的副作用。'}
        1068 {$category='DependencyUnavailable';$hint='相依服務或群組啟動失敗；逐項確認相依服務與業務端點，不能略過相依門檻。'}
        1069 {$category='AccountLogon';$hint='服務帳號登入失敗；核對已審核帳號、記憶體認證、登入為服務權限及網域狀態，不輸出密碼。'}
        1219 {$category='CredentialConflict';$hint='現有 SMB 連線使用不同認證；核對連線與所有權，避免自動斷開使用者或業務工作階段。'}
        1231 {$category='DependencyUnavailable';$hint='網路不可達；核對核准 IP／DNS／路由與 provider 狀態，保留中斷證據。'}
    }}
    if($null -ne $code -and [int]$code -in @(1314,1300)){$category='Privilege';$hint='原生 API 所需 token privilege 未配置或無法啟用；核對服務帳號與系統安全性原則後再預檢。'}
    elseif($null -ne $code -and [int]$code -in @(1722,1726)){$category='DependencyUnavailable';$hint='RPC 或相依服務不可用；核對本機相依、端點與實際副作用，保留檢查點再修復。'}
    elseif($null -ne $code -and [int]$code -in @(1618,1056)){$category='OperationInProgress';$hint='另一個原生操作仍在進行；先確認現況，不能重複啟動安裝或服務。'}
    [pscustomobject]@{ExitCode=$(if($category -ceq 'Cancelled'){3}elseif($category -ceq 'InputValidation'){4}else{1});NativeDiagnostics=([pscustomobject]$nativeDiagnostics);Category=$category;NativeCode=$code;NativeTool=$nativeTool;NativeResult=$nativeResult;HResult=$hresult;Hint=$hint;AutomaticRetrySafe=$false;RawOutputIncluded=$false}
}
function New-WsmNativeFailure([string]$Tool,[int]$Code,[string]$Operation) {
    $error=New-Object InvalidOperationException(($Operation+' failed; '+$Tool+' native code '+$Code));$error.Data['NativeCode']=$Code;$error.Data['NativeTool']=$Tool;$error
}
