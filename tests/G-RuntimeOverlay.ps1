# Test-only runtime overlay for the offline restore journey (G). Its text is appended
# to the psm1 of an EXECUTION COPY of the immutable snapshot (never to the snapshot
# itself) because Start-WsmHtmlConsole runs every operation in worker runspaces that
# re-import the module from disk, so module-scope replacements made after a normal
# import are invisible to them. It is inert unless WSM_G_OVERLAY=1.
if ($env:WSM_G_OVERLAY -eq '1') {
    function Write-GTrace([string]$Kind,$Data) {
        $path=[string]$env:WSM_G_TRACE
        if(-not $path){return}
        $row=[ordered]@{Utc=[DateTime]::UtcNow.ToString('o');Pid=$PID;Kind=$Kind;Data=$Data}
        $line=($row | ConvertTo-Json -Compress -Depth 8)+[Environment]::NewLine
        $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($line)
        $stream=$null
        for($attempt=0;$attempt -lt 50 -and -not $stream;$attempt++){
            try{$stream=[IO.File]::Open($path,'Append','Write','ReadWrite')}catch [IO.IOException]{Start-Sleep -Milliseconds 20}
        }
        if($stream){try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}}
    }

    # Platform qualification observation only (this runner is a non-server, non-admin box).
    function Get-WsmPreflight {
        [pscustomobject]@{OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true;PowerShellVersion='5.1';ExecutionPolicy='AllSigned';LanguageMode='FullLanguage'}
    }

    # Raw failure observation (the product returns only a generic safe error to the browser).
    $script:GOriginalSafeError=(Get-Command Get-WsmHtmlSafeError -CommandType Function).ScriptBlock
    function Get-WsmHtmlSafeError([string]$ExceptionMessage,[string]$ExceptionType='') {
        $record=if($_ -is [Management.Automation.ErrorRecord]){$_}else{$null}
        Write-GTrace 'SafeErrorSource' ([ordered]@{Message=$ExceptionMessage;Type=$ExceptionType;Stack=$(if($record){[string]$record.ScriptStackTrace}else{''})})
        & $script:GOriginalSafeError $ExceptionMessage $ExceptionType
    }

    # Identity override for the negative (R8) consoles: another machine, optionally with this machine's name.
    if($env:WSM_G_FAKE_FINGERPRINT){
        $script:GOriginalIdentity=(Get-Command Get-WsmMachineIdentity -CommandType Function).ScriptBlock
        function Get-WsmMachineIdentity {
            $identity=& $script:GOriginalIdentity
            $identity.Fingerprint=[string]$env:WSM_G_FAKE_FINGERPRINT
            if($env:WSM_G_FAKE_NAME){$identity.Name=[string]$env:WSM_G_FAKE_NAME}
            $identity
        }
    }

    # Pre-seeded Target inventory (the real full local inventory takes far too long on this client box). The
    # live software observation used by the freshness/currentness gates returns the catalog of the newest seeded
    # inventory; when the marker file named by WSM_G_EXTRA_CATALOG exists, one extra product is "installed" later.
    $script:GSeededInventoryPath=[string]$env:WSM_G_TARGET_INVENTORY
    if($script:GSeededInventoryPath){
        $script:GOriginalSoftwareCatalog=(Get-Command Get-WsmSoftwareCatalog -CommandType Function).ScriptBlock
        function Get-WsmSoftwareCatalog {
            [CmdletBinding()]param($Source,[string[]]$PortableRoot=@(),[int]$MaxEntries=10000,[int]$MaxDepth=8,[long]$MaxMetadataBytes=4194304,[string]$ManualEvidencePath,[string]$ManualEvidenceSha256)
            $directory=[IO.Path]::GetDirectoryName($script:GSeededInventoryPath)
            $newest=$null;if([IO.Directory]::Exists($directory)){$newest=@(Get-ChildItem -LiteralPath $directory -Filter 'inventory-*.json' -File | Sort-Object {[int]($_.BaseName -replace '\D','')})|Select-Object -Last 1}
            if($newest -and $Source -and $Source.PSObject.Properties['Source']){
                $seeded=Read-WsmJson $newest.FullName
                if([string]$Source.Source.Fingerprint -ceq [string]$seeded.Source.Fingerprint -and $seeded.PSObject.Properties['SoftwareCatalog']){
                    $catalog=$seeded.SoftwareCatalog
                    $extra=[string]$env:WSM_G_EXTRA_CATALOG
                    $extraId='sw-0000000000000000000000000000b2b2'
                    if($extra -and [IO.File]::Exists($extra) -and -not @($catalog.Entries | Where-Object SoftwareId -ceq $extraId).Count){
                        $now=[DateTime]::UtcNow.ToString('o')
                        $entry=[pscustomobject][ordered]@{SoftwareId=$extraId;Name='G Later Install';Version='3.0.0';Publisher='G Test';Architecture='x64';Scope='Machine';SID='';RegistryView='Registry64';Location='fixture:G Later Install';SourceKind='Registry';Evidence=[pscustomobject]@{Probe='Uninstall'};ObservedUtc=$now;CaptureStatus='Success';ItemIds=@();AccountContext='Unknown'}
                        $catalog.Entries=@($catalog.Entries)+@($entry)
                        $catalog.PreparationRequirements=@($catalog.PreparationRequirements)+@([pscustomobject]@{PreparationId='prep-0000000000000000000000000000b2b2';SoftwareId=$extraId;Status='NeedsOwnerReview';RequiredPhase='PreparationReady';EvidenceStatus='Success';ConsumerItemIds=@();Owner='';Reason='G journey fixture evidence only.'})
                        $catalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $catalog
                    }
                    return $catalog
                }
            }
            & $script:GOriginalSoftwareCatalog @PSBoundParameters
        }
    }

    # Source/Manager fallback guard: any path under a forbidden root is recorded and refused.
    $script:GForbiddenRoots=@(([string]$env:WSM_G_FORBIDDEN_ROOTS -split ';') | Where-Object {$_} | ForEach-Object {[IO.Path]::GetFullPath($_).TrimEnd('\')+'\'})
    $script:GOriginalAssertNoReparse=(Get-Command Assert-WsmNoReparse -CommandType Function).ScriptBlock
    function Assert-WsmNoReparse([string]$Path) {
        if($script:GForbiddenRoots.Count -and $Path){
            $full=$null;try{$full=[IO.Path]::GetFullPath($Path)}catch{}
            if($full){
                foreach($root in $script:GForbiddenRoots){
                    if(($full.TrimEnd('\')+'\').StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){Write-GTrace 'ForbiddenAccess' ([ordered]@{Path=$full;Root=$root});throw 'G journey: access to a cut-off Source/Manager workspace was attempted.'}
                }
            }
        }
        & $script:GOriginalAssertNoReparse $Path
    }

    # Narrow Service boundary (credential consumer double): the account and the credential
    # binding are observed, no real Windows service is created. Applications are counted.
    function Test-GServiceSpec($Spec) { [string]$Spec.Adapter -ceq 'Service' -and [string]$Spec.AccountMode -ceq 'UserPassword' }
    function Read-GServiceFixture {
        $path=[string]$env:WSM_G_SERVICE_FIXTURE
        if($path -and [IO.File]::Exists($path)){return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)}
        $null
    }
    $script:GOriginalAdapterState=(Get-Command Get-WsmAdapterState -CommandType Function).ScriptBlock
    function Get-WsmAdapterState($Spec) {
        if(Test-GServiceSpec $Spec){
            $fixture=Read-GServiceFixture
            if($fixture -and [string]$fixture.Name -ceq [string]$Spec.Desired.Name){
                return [pscustomobject]@{Exists=$true;Configuration=[pscustomobject]@{Name=[string]$fixture.Name;DisplayName=[string]$Spec.Desired.DisplayName;Description=[string]$Spec.Desired.Description;PathName=[string]$Spec.Desired.BinaryPathName;StartMode='Disabled';StartName=[string]$fixture.Account};Supplement=$Spec.Desired.Supplement;State='Stopped';Dependencies=@()}
            }
            return [pscustomobject]@{Exists=$false}
        }
        & $script:GOriginalAdapterState $Spec
    }
    $script:GOriginalAdapterRestore=(Get-Command Invoke-WsmAdapterRestore -CommandType Function).ScriptBlock
    function Invoke-WsmAdapterRestore($Spec,[hashtable]$Secrets,$Package,$InstallerBaseline=$null,[scriptblock]$BeforeFolderCreate,[scriptblock]$AfterFolderCreate,[object[]]$OwnedReceipts=@(),[object[]]$SharedReceipts=@(),[string]$ReservationWorkspace='',[string]$ReservationOperationId='') {
        if(Test-GServiceSpec $Spec){
            $credential=$Secrets[[string]$Spec.SecretRef]
            $bound=($credential -is [Management.Automation.PSCredential])
            $accountMatches=$bound -and ($credential.UserName -ceq [string]$Spec.Desired.Account)
            $secretMatches=$bound -and ($credential.GetNetworkCredential().Password -ceq [string]$env:WSM_G_EXPECTED_PASSWORD)
            Write-GTrace 'ServiceApply' ([ordered]@{ServiceName=[string]$Spec.Desired.Name;ApprovedAccount=[string]$Spec.Desired.Account;ReceivedAccount=$(if($bound){[string]$credential.UserName}else{''});CredentialBound=$bound;AccountMatches=$accountMatches;SecretMatchesExpected=$secretMatches})
            if(-not $accountMatches -or -not $secretMatches){throw 'G journey Service boundary rejected a credential that is not the approved account and secret.'}
            $already=Read-GServiceFixture
            if($already){throw 'G journey Service boundary was asked to create an already existing service.'}
            $fixturePath=[string]$env:WSM_G_SERVICE_FIXTURE
            [IO.File]::WriteAllText($fixturePath,([ordered]@{Name=[string]$Spec.Desired.Name;Account=[string]$credential.UserName;AppliedUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
            return [pscustomobject]@{RebootRequired=$false;AuxiliaryOwnership=@()}
        }
        & $script:GOriginalAdapterRestore $Spec $Secrets $Package $InstallerBaseline $BeforeFolderCreate $AfterFolderCreate $OwnedReceipts $SharedReceipts $ReservationWorkspace $ReservationOperationId
    }

    # Journal observation and the single crash point: the first FileScope file whose native
    # write has finished (target holds the sealed bytes) but whose AssistiveFileCompleted
    # journal row has not been written is where the process dies (exit code 137).
    $script:GOriginalAddJournal=(Get-Command Add-WsmJournal -CommandType Function).ScriptBlock
    function Add-WsmJournal($Paths,$State,[string]$Action,[string]$ItemId,$Detail) {
        $targetPath='';if($Detail -and $Detail.PSObject.Properties['Target']){$targetPath=[string]$Detail.Target}
        if(-not $targetPath -and $Detail -and $Detail.PSObject.Properties['Record'] -and $Detail.Record -and $Detail.Record.PSObject.Properties['TargetPath']){$targetPath=[string]$Detail.Record.TargetPath}
        Write-GTrace 'Journal' ([ordered]@{Action=$Action;ItemId=$ItemId;Target=$targetPath})
        $marker=[string]$env:WSM_G_CRASH_MARKER
        $completedSoFar=0
        if($marker -and $env:WSM_G_CRASH_ON_COMPLETED -eq '1' -and $Action -ceq 'AssistiveFileCompleted' -and -not [IO.File]::Exists($marker) -and $env:WSM_G_TRACE -and [IO.File]::Exists($env:WSM_G_TRACE)){
            $completedSoFar=@(Get-Content -LiteralPath $env:WSM_G_TRACE -Encoding UTF8 | Where-Object {$_ -like '*"Action":"AssistiveFileCompleted"*'}).Count
        }
        if($completedSoFar -ge [int]$(if($env:WSM_G_CRASH_NTH){$env:WSM_G_CRASH_NTH}else{1})){
            $exists=[IO.File]::Exists($targetPath)
            $hash='';if($exists){$hash=(Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()}
            [IO.File]::WriteAllText($marker,([ordered]@{Target=$targetPath;TargetExists=$exists;TargetSHA256=$hash;ExpectedSHA256=$(if($Detail -and $Detail.Record){[string]$Detail.Record.SHA256}else{''});ItemId=$ItemId;Pid=$PID;Utc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
            Write-GTrace 'CrashPoint' ([ordered]@{Target=$targetPath;TargetExists=$exists})
            [Environment]::Exit(137)
        }
        & $script:GOriginalAddJournal $Paths $State $Action $ItemId $Detail
    }
}
