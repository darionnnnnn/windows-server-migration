#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$helper=Join-Path $PSScriptRoot '..\src\AssistiveRestore.ps1'
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-assistive-directory-readback-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($root,$helper)
        . $helper
        $script:checks=0;$script:entries=@()
        $script:nativeMetadataAssert=(Get-Command Assert-WsmAssistiveMetadataReadback -CommandType Function).ScriptBlock;$script:metadataAssertErrors=@{}
        function Assert-WsmAssistiveMetadataReadback([string]$Path,$Expected,[hashtable]$SidMap,[string]$AclPolicy='Exact') {try{return (& $script:nativeMetadataAssert $Path $Expected $SidMap $AclPolicy)}catch{$script:metadataAssertErrors[$Path]=$_.Exception.Message;throw}}
        function Check([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:checks++}
        function Read-WsmArtifactLines($Path,$Hash,$CancellationToken){$script:entries}
        function Restore-WsmPayloadBytes($Entry,$PackageRoot,$Destination,$CancellationToken){[IO.File]::Copy([string]$Entry.Data.SourcePath,$Destination,$true)}
        function Add-WsmJournal($Paths,$State,[string]$Action,[string]$ItemId,$Detail){ }
        function New-DirectoryEntry([string]$ItemId,[string]$RelativePath,[string]$Path){[pscustomobject]@{ItemId=$ItemId;RelativePath=$RelativePath;Directory=$true;Data=$null;Metadata=(Get-WsmFileMetadata $Path 'DaclOwner')}}
        function New-FileEntry([string]$ItemId,[string]$RelativePath,[string]$Path){$hash=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant();[pscustomobject]@{ItemId=$ItemId;RelativePath=$RelativePath;Directory=$false;Data=[pscustomobject]@{Hash=$hash;Bytes=([IO.FileInfo]$Path).Length;SourcePath=$Path};Metadata=(Get-WsmFileMetadata $Path 'DaclOwner')}}
        function Add-InheritableEveryoneRead([string]$Path){$acl=Get-Acl -LiteralPath $Path;$sid=New-Object Security.Principal.SecurityIdentifier('S-1-1-0');$flags=[Security.AccessControl.InheritanceFlags]([int][Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [int][Security.AccessControl.InheritanceFlags]::ObjectInherit);$rule=[Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::Read,$flags,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow);[void]$acl.AddAccessRule($rule);Set-Acl -LiteralPath $Path -AclObject $acl}
        function Set-ExplicitFixtureDirectoryAcl([string]$Path,[bool]$EveryoneRead){$acl=Get-Acl -LiteralPath $Path;$acl.SetAccessRuleProtection($true,$false);$inherit=[Security.AccessControl.InheritanceFlags]([int][Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [int][Security.AccessControl.InheritanceFlags]::ObjectInherit);$ids=@([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544');foreach($id in $ids){$sid=New-Object Security.Principal.SecurityIdentifier($id);$rule=[Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow);[void]$acl.AddAccessRule($rule)};if($EveryoneRead){$everyone=New-Object Security.Principal.SecurityIdentifier('S-1-1-0');$readRule=[Security.AccessControl.FileSystemAccessRule]::new($everyone,[Security.AccessControl.FileSystemRights]::Read,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow);[void]$acl.AddAccessRule($readRule)};Set-Acl -LiteralPath $Path -AclObject $acl}
        function New-RunContext([string]$Target,[string]$ItemId){$item=[pscustomobject]@{ItemId=$ItemId;MigrationSpec=[pscustomobject]@{Adapter='FileScope';TargetPath=$Target;Metadata='DaclOwner';AclControlPolicy='Exact'}};$package=[pscustomobject]@{Root=$root;SHA256=('a'*64);Manifest=[pscustomobject]@{Generation=1;ArtifactsHash=('b'*64)}};$state=[pscustomobject]@{Items=@();PendingOperations=@()};$paths=[pscustomobject]@{Root=$root;State='';Journal=''};[pscustomobject]@{Item=$item;Package=$package;State=$state;Paths=$paths}}

        $itemId='b123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

        # Negative: the source file inherits a new parent ACE, but the target parent has not
        # received the corresponding reviewed mapping when file metadata is first read back.
        $negativeSource=Join-Path $root 'negative-source';$negativeNested=Join-Path $negativeSource 'nested';[void][IO.Directory]::CreateDirectory($negativeNested);Add-InheritableEveryoneRead $negativeSource
        $negativeFile=Join-Path $negativeNested 'worker.ini';[IO.File]::WriteAllText($negativeFile,'approved bytes')
        $negativeRootMeta=Get-WsmFileMetadata $negativeSource 'DaclOwner';$negativeNestedMeta=Get-WsmFileMetadata $negativeNested 'DaclOwner';$negativeFileMeta=Get-WsmFileMetadata $negativeFile 'DaclOwner'
        $negativeTarget=Join-Path $root 'negative-target';$script:entries=@((New-DirectoryEntry $itemId '' $negativeSource),(New-DirectoryEntry $itemId 'nested' $negativeNested),(New-FileEntry $itemId 'nested\worker.ini' $negativeFile))
        $negative=New-RunContext $negativeTarget $itemId;$negativeResult=Invoke-WsmAssistiveFileScopeRestore $negative.Item $negative.Package $negative.Paths $negative.State @{} $null
        $negativeTargetFile=Join-Path $negativeTarget 'nested\worker.ini'
        Check ($negativeResult.Status -ne 'Succeeded' -and @($negativeResult.FileResults|Where-Object Status -eq 'Failed').Count -eq 1) ('Target without mapped parent ACL must not succeed; source-file metadata hash='+(Get-WsmAssistiveMetadataHash $negativeFileMeta)+'; fileApplied='+[IO.File]::Exists($negativeTargetFile))
        Check (-not [IO.File]::Exists($negativeTargetFile) -and @($negativeResult.OwnedFiles).Count -eq 0) 'Mismatched sealed child ACL was written/adopted despite the initial native metadata readback failure.'
        $negativeSourceSddlHash=Get-WsmHashText ([string]$negativeFileMeta.Sddl);$negativeMappedSddlHash=Get-WsmHashText (Convert-WsmMappedSddl ([string]$negativeFileMeta.Sddl) @{})

        # Controlled mixed-generation fixture: the sealed file ACL matches the target parent
        # during the first real readback, while a later directory row carries a different
        # inheritable ACL. This intentionally inconsistent package must fail final readback.
        $postCleanRoot=Join-Path $root 'post-clean-source';$postCleanNested=Join-Path $postCleanRoot 'nested';[void][IO.Directory]::CreateDirectory($postCleanNested);Set-ExplicitFixtureDirectoryAcl $postCleanRoot $false;Set-ExplicitFixtureDirectoryAcl $postCleanNested $false
        $postCleanFile=Join-Path $postCleanNested 'worker.ini';[IO.File]::WriteAllText($postCleanFile,'approved bytes')
        $postAclParent=Join-Path $root 'post-acl-source';[void][IO.Directory]::CreateDirectory($postAclParent);Set-ExplicitFixtureDirectoryAcl $postAclParent $true
        $postCleanRootMeta=Get-WsmFileMetadata $postCleanRoot 'DaclOwner';$postAclParentMeta=Get-WsmFileMetadata $postAclParent 'DaclOwner';$postCleanFileMeta=Get-WsmFileMetadata $postCleanFile 'DaclOwner'
        $postTarget=Join-Path $root 'post-target';$postTargetFile=Join-Path $postTarget 'nested\worker.ini';$script:entries=@((New-DirectoryEntry $itemId '' $postCleanRoot),(New-DirectoryEntry $itemId 'nested' $postAclParent),(New-FileEntry $itemId 'nested\worker.ini' $postCleanFile))
        $post=New-RunContext $postTarget $itemId;$postResult=Invoke-WsmAssistiveFileScopeRestore $post.Item $post.Package $post.Paths $post.State @{} $null
        $postFileResults=@($postResult.FileResults|Where-Object RelativePath -CEQ 'nested\worker.ini');$postTargetFileExists=[IO.File]::Exists($postTargetFile)
        $postFileRowText=(@($postFileResults|ForEach-Object {($_|ConvertTo-Json -Depth 8 -Compress)}) -join '; ')
        $postOwnedText=(@($postResult.OwnedFiles|ForEach-Object {($_|ConvertTo-Json -Depth 8 -Compress)}) -join '; ');$postNestedPath=Join-Path $postTarget 'nested';$postNestedEntries=''
        try{$postNestedEntries=(@([IO.Directory]::EnumerateFileSystemEntries($postNestedPath)) -join '|')}catch{$postNestedEntries='enumeration-error='+$_.Exception.GetType().FullName}
        $postMetadataErrorText=($script:metadataAssertErrors|ConvertTo-Json -Depth 8 -Compress)
        Write-Host ('REPRO restore invocation: target='+$postTarget+'; target-directory-exists='+[IO.Directory]::Exists($postTarget)+'; nested-directory-exists='+[IO.Directory]::Exists($postNestedPath)+'; nested-entries='+$postNestedEntries+'; target-file-exists='+$postTargetFileExists+'; restore-status='+$postResult.Status+'; error='+[string]$postResult.Error+'; file-results='+$postFileRowText+'; owned-files='+$postOwnedText+'; metadata-readback-errors='+$postMetadataErrorText)
        Check ($postTargetFileExists) ('Restore did not materialize the expected target file before native metadata readback; status='+$postResult.Status+'; result='+$postFileRowText+'; owned-files='+$postOwnedText+'; metadata-readback-errors='+$postMetadataErrorText+'; target-root='+$postTarget+'; source-file='+$postCleanFile)
        $postActual=Get-WsmFileMetadata $postTargetFile 'DaclOwner'
        $postSealedSddlHash=Get-WsmHashText ([string]$postCleanFileMeta.Sddl);$postParentSddlHash=Get-WsmHashText ([string]$postAclParentMeta.Sddl);$postFinalSddlHash=Get-WsmHashText ([string]$postActual.Sddl);$postSealedMetadataHash=Get-WsmAssistiveMetadataHash $postCleanFileMeta;$postPreDirectoryOwnedHash=[string]$postResult.OwnedFiles[0].MetadataHash;$postFinalMetadataHash=Get-WsmAssistiveMetadataHash $postActual
        Write-Host ('REPRO mixed-generation sealed child SDDL SHA256='+$postSealedSddlHash+'; parent SDDL SHA256='+$postParentSddlHash+'; final child SDDL SHA256='+$postFinalSddlHash+'; sealed metadata hash='+$postSealedMetadataHash+'; pre-directory OwnedFiles hash='+$postPreDirectoryOwnedHash+'; final actual metadata hash='+$postFinalMetadataHash+'; restore status='+$postResult.Status+'; file result='+[string]$postFileResults[0].MetadataStatus)
        Check ([IO.File]::Exists($postTargetFile) -and @($postResult.OwnedFiles).Count -eq 1) 'Mixed-generation fixture did not pass initial file metadata readback and reach post-directory verification.'
        Check ($postResult.Status -eq 'Failed' -and $postFileResults.Count -eq 1 -and $postFileResults[0].MetadataStatus -ceq 'FinalReadbackFailed') ('Parent ACL propagation after the initial file readback was reported successful; status='+$postResult.Status+'; final result='+[string]$postFileResults[0].MetadataStatus)
        Check ((Get-WsmAssistiveMetadataHash $postActual) -cne [string]$postResult.OwnedFiles[0].MetadataHash) 'Mixed-generation child ACL fixture did not create final metadata drift for the final-readback gate.'

        # Positive: preconfigure an existing target root with the explicit reviewed SID mapping.
        # Newly created children inherit that mapped ACL before file staging, then remain equal
        # after the native directory metadata application and final ownership readback.
        $positiveSource=Join-Path $root 'positive-source';$positiveNested=Join-Path $positiveSource 'nested';[void][IO.Directory]::CreateDirectory($positiveNested);Add-InheritableEveryoneRead $positiveSource
        $positiveFile=Join-Path $positiveNested 'worker.ini';[IO.File]::WriteAllText($positiveFile,'approved bytes')
        $positiveRootMeta=Get-WsmFileMetadata $positiveSource 'DaclOwner';$positiveNestedMeta=Get-WsmFileMetadata $positiveNested 'DaclOwner';$positiveFileMeta=Get-WsmFileMetadata $positiveFile 'DaclOwner'
        $targetRoot=Join-Path $root 'positive-target';[void][IO.Directory]::CreateDirectory($targetRoot)
        $currentSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$sidMap=@{'S-1-1-0'=$currentSid};Set-WsmFileMetadata $targetRoot $positiveRootMeta $sidMap
        $positiveNestedNow=Join-Path $targetRoot 'nested';$script:entries=@((New-DirectoryEntry $itemId '' $positiveSource),(New-DirectoryEntry $itemId 'nested' $positiveNested),(New-FileEntry $itemId 'nested\worker.ini' $positiveFile))
        $positive=New-RunContext $targetRoot $itemId;$positiveResult=Invoke-WsmAssistiveFileScopeRestore $positive.Item $positive.Package $positive.Paths $positive.State $sidMap $null
        $positiveTargetFile=Join-Path $positiveNestedNow 'worker.ini';$positiveActual=Get-WsmFileMetadata $positiveTargetFile 'DaclOwner';$positiveOwned=@($positiveResult.OwnedFiles|Where-Object RelativePath -CEQ 'nested\worker.ini')
        Check ($positiveResult.Status -eq 'Succeeded' -and @($positiveOwned).Count -eq 1) 'Correctly mapped parent/child ACL did not produce a successful file restore.'
        Check ((Get-WsmAssistiveMetadataHash $positiveActual) -ceq [string]$positiveOwned[0].MetadataHash) 'Owned file metadata hash does not match final native target readback after all directory ACLs were applied.'
        $expectedMappedSddl=Convert-WsmMappedSddl ([string]$positiveFileMeta.Sddl) $sidMap
        Check ($positiveActual.Sddl -ceq $expectedMappedSddl) 'Final native file ACL differs from the exact SID-mapped source file ACL.'
        $positiveMappedSddlHash=Get-WsmHashText $expectedMappedSddl
        Write-Host ('PASS: '+$script:checks+' native Assistive directory/readback checks.')
        Write-Host ('REPRO negative source SDDL SHA256='+$negativeSourceSddlHash+'; mapped SDDL SHA256='+$negativeMappedSddlHash+'; restore status='+$negativeResult.Status+'; child write attempted='+[IO.File]::Exists($negativeTargetFile))
        Write-Host ('REPRO mixed-generation sealed child SDDL SHA256='+$postSealedSddlHash+'; parent SDDL SHA256='+$postParentSddlHash+'; final child SDDL SHA256='+$postFinalSddlHash+'; sealed metadata hash='+$postSealedMetadataHash+'; pre-directory OwnedFiles hash='+$postPreDirectoryOwnedHash+'; final actual metadata hash='+$postFinalMetadataHash+'; restore status='+$postResult.Status+'; file result='+[string]$postFileResults[0].MetadataStatus)
        Write-Host ('REPRO positive mapped source SDDL SHA256='+$positiveMappedSddlHash+'; final native metadata hash='+ (Get-WsmAssistiveMetadataHash $positiveActual)+'; OwnedFiles.MetadataHash='+[string]$positiveOwned[0].MetadataHash)
    } $root $helper
} finally {Remove-Item -LiteralPath $root -Recurse -Force}
