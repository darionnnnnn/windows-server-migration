#requires -Version 5.1
# Q5(d)：工具擁有的目錄帶可繼承 ACE，套用或回復「目錄」ACL 時，Windows 會把它傳播到底下未保護的子檔；
# 沿用既有檔（OwnedFiles[].Ownership='AdoptedExisting'）不是工具寫的，SDDL 與內容都不得被改。
#   Part A：用真實的 NTFS 繼承傳播驗證兩個 helper（Get-/Restore-WsmAdoptedFileAclSnapshots）：
#           對照組（一般工具擁有的檔）照原本行為繼承；沿用檔在套用、回復之後 SDDL 位元組與內容都不變；已 protected 的沿用檔不受影響。
#   Part B：靜態守門：套用端（Invoke-WsmAssistiveFileScopeRestore）與回復端（Complete-WsmAssistiveFileRollback）改目錄 ACL 的迴圈
#           都包在 try/finally 內，finally 呼叫還原，且保存動作在 try 之前。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking -WarningAction SilentlyContinue
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-q5d-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
$srcDir=Join-Path $PSScriptRoot '..\src'
try {
    & $module {
        param($Root,$SrcDir)
        $script:q5Checks=0
        function Check([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:q5Checks++}
        $sections=[Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group
        $guestsSid=([Security.Principal.NTAccount]'Guests').Translate([Security.Principal.SecurityIdentifier]).Value
        function HasGuests([string]$s){$s.Contains($guestsSid) -or $s -cmatch ';;;BG\)'}
        function Sddl([string]$path){(Get-Acl -LiteralPath $path).GetSecurityDescriptorSddlForm($sections)}
        function Sha([string]$path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
        function AddRule([string]$path,[string]$identity){$acl=Get-Acl -LiteralPath $path;$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity,'Read','ContainerInherit,ObjectInherit','None','Allow')));$acl.GetSecurityDescriptorSddlForm($sections)}

        # ---------------- Part A ----------------
        $dir=Join-Path $Root 'owned-dir';[void][IO.Directory]::CreateDirectory($dir)
        $adopted=Join-Path $dir 'adopted.txt';$tool=Join-Path $dir 'tool.txt';$prot=Join-Path $dir 'protected.txt';$outside=Join-Path $Root 'outside.txt'
        foreach($f in @($adopted,$tool,$prot,$outside)){[IO.File]::WriteAllText($f,('content of '+[IO.Path]::GetFileName($f)))}
        $acl=Get-Acl -LiteralPath $prot;$acl.SetAccessRuleProtection($true,$true);Set-Acl -LiteralPath $prot -AclObject $acl
        $facts=@{};foreach($f in @($adopted,$tool,$prot,$outside)){$facts[$f]=[pscustomobject]@{Sddl=(Sddl $f);Sha=(Sha $f)}}
        $records=@(
            [pscustomobject]@{RelativePath='adopted.txt';TargetPath=$adopted;Ownership='AdoptedExisting'},
            [pscustomobject]@{RelativePath='tool.txt';TargetPath=$tool},
            [pscustomobject]@{RelativePath='protected.txt';TargetPath=$prot;Ownership='AdoptedExisting'},
            [pscustomobject]@{RelativePath='gone.txt';TargetPath=(Join-Path $dir 'gone.txt');Ownership='AdoptedExisting'},
            [pscustomobject]@{RelativePath='..\outside.txt';TargetPath=$outside;Ownership='AdoptedExisting'}
        )
        $snapshots=@(Get-WsmAdoptedFileAclSnapshots $records $dir)
        Check ($snapshots.Count -eq 2 -and (@($snapshots|ForEach-Object {$_.Path}|Sort-Object) -join '|') -ceq ((@($adopted,$prot)|Sort-Object) -join '|')) ('A1: only existing adopted files under the directory are snapshotted (got '+$snapshots.Count+').')
        Check (@(Get-WsmAdoptedFileAclSnapshots @() $dir).Count -eq 0 -and @(Get-WsmAdoptedFileAclSnapshots $null $dir).Count -eq 0) 'A1: no records gives no snapshots.'

        $dirMeta=Get-WsmFileMetadata $dir 'DaclOwner'
        $newMeta=$dirMeta.PSObject.Copy();$newMeta.Sddl=AddRule $dir 'Guests'
        # AddRule only computed an SDDL string through the ACL object; the real directory ACL is still the original
        Check ((Sddl $dir) -ceq $dirMeta.Sddl) 'A2: fixture error, the directory ACL was changed while building the new SDDL.'

        # ---- apply leg: control first (no protection) to prove the fixture really propagates ----
        Set-WsmFileMetadata $dir $newMeta @{}
        Check ((Sddl $adopted) -cne $facts[$adopted].Sddl -and (HasGuests (Sddl $adopted))) 'A3 control: without protection the directory ACL change DOES propagate to the adopted file (the defect this guards against).'
        Check ((Sddl $tool) -cne $facts[$tool].Sddl -and (HasGuests (Sddl $tool))) 'A3 control: a normal tool-owned file inherits the new ACE.'
        Check ((Sddl $prot) -ceq $facts[$prot].Sddl) 'A3 control: a protected file is not touched by propagation.'
        Restore-WsmAdoptedFileAclSnapshots $snapshots
        Check ((Sddl $adopted) -ceq $facts[$adopted].Sddl) 'A3: the adopted file SDDL is byte-identical after the apply leg and the restore.'
        Check ((Sha $adopted) -ceq $facts[$adopted].Sha) 'A3: the adopted file content is unchanged.'
        Check ((Sddl $prot) -ceq $facts[$prot].Sddl) 'A3: the protected adopted file is unchanged.'
        Check ((HasGuests (Sddl $tool)) -and (Sddl $tool) -cne $facts[$tool].Sddl) 'A3: the normal tool-owned file keeps inheriting (the restore must not touch it).'
        Check ((Sddl $outside) -ceq $facts[$outside].Sddl) 'A3: a file outside the directory is untouched.'
        Check (HasGuests (Sddl $dir)) 'A3: the directory itself keeps the new ACL.'

        # ---- full wrapped legs (the shape the two call sites use): apply the new ACL, then roll the directory ACL back ----
        $snap2=@(Get-WsmAdoptedFileAclSnapshots $records $dir)
        try{Set-WsmFileMetadata $dir $newMeta @{}}finally{Restore-WsmAdoptedFileAclSnapshots $snap2}
        Check ((Sddl $adopted) -ceq $facts[$adopted].Sddl) 'A4: wrapped apply keeps the adopted SDDL.'
        $snap3=@(Get-WsmAdoptedFileAclSnapshots $records $dir)
        try{Set-WsmFileMetadata $dir $dirMeta @{}}finally{Restore-WsmAdoptedFileAclSnapshots $snap3}
        Check ((Sddl $adopted) -ceq $facts[$adopted].Sddl -and (Sha $adopted) -ceq $facts[$adopted].Sha) 'A4: after apply and rollback the adopted file SDDL and content are byte-identical to the start.'
        Check ((Sddl $tool) -ceq $facts[$tool].Sddl) 'A4: the normal tool-owned file followed the rollback (inherits the original ACL again).'
        Check ((Sddl $prot) -ceq $facts[$prot].Sddl -and (Sddl $dir) -ceq $dirMeta.Sddl) 'A4: protected file unchanged and the directory is back to its original SDDL.'

        # restore is a no-op when nothing changed, and skips a file that disappeared
        Restore-WsmAdoptedFileAclSnapshots $snap3
        Check ((Sddl $adopted) -ceq $facts[$adopted].Sddl) 'A5: restoring an unchanged snapshot is a no-op.'
        Remove-Item -LiteralPath $adopted -Force
        Restore-WsmAdoptedFileAclSnapshots $snapshots
        Check (-not [IO.File]::Exists($adopted)) 'A5: a snapshotted file that disappeared is skipped, never recreated.'

        # ---------------- Part B: static guard ----------------
        function Get-FunctionAst([string]$file,[string]$name){
            $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SrcDir $file),[ref]$null,[ref]$null)
            $found=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));if($found.Count -ne 1){throw ('B: '+$file+':'+$name+' not found exactly once.')};$found[0]
        }
        function Assert-Guarded($fn,[string]$label){
            $tries=@($fn.Body.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst] -and $n.Finally -and $n.Finally.Extent.Text.Contains('Restore-WsmAdoptedFileAclSnapshots') -and $n.Body.Extent.Text.Contains('Set-WsmFileMetadata')},$true))
            Check ($tries.Count -ge 1) ($label+': the directory metadata loop is not inside a try whose finally calls Restore-WsmAdoptedFileAclSnapshots.')
            $snapshotCalls=@($fn.Body.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Get-WsmAdoptedFileAclSnapshots'},$true))
            Check ($snapshotCalls.Count -ge 1 -and $snapshotCalls[0].Extent.StartOffset -lt $tries[0].Extent.StartOffset) ($label+': the adopted-file snapshot is not taken before the guarded try.')
        }
        Assert-Guarded (Get-FunctionAst 'AssistiveRestore.ps1' 'Invoke-WsmAssistiveFileScopeRestore') 'B1 apply'
        Assert-Guarded (Get-FunctionAst 'Recovery.ps1' 'Complete-WsmAssistiveFileRollback') 'B2 rollback'
        Write-Host ('PASS: adopted-file ACL propagation ('+$script:q5Checks+' checks): real NTFS inheritance control, adopted SDDL byte-identical after apply and rollback, tool-owned files still inherit, protected and missing files handled, both call sites guarded by try/finally.')
    } $root $srcDir
} finally {
    if([IO.Directory]::Exists($root)){try{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop}catch{Write-Warning ('Test cleanup could not remove '+$root+': '+$_.Exception.Message)}}
}
