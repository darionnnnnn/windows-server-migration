#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$helper=Join-Path $PSScriptRoot '..\src\AssistiveRestore.ps1'
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-assistive-restore-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($root,$helper)
        . $helper
        $script:originalGetWsmOperationPaths=(Get-Command Get-WsmOperationPaths -CommandType Function).ScriptBlock
        $script:originalGetWsmOperationState=(Get-Command Get-WsmOperationState -CommandType Function).ScriptBlock
        $script:originalAddWsmJournal=(Get-Command Add-WsmJournal -CommandType Function).ScriptBlock
        $script:nativeAssistiveFileTopology=(Get-Command Assert-WsmAssistiveFileTopology -CommandType Function).ScriptBlock;$script:rejectAssistiveTopologyPath=''
        Set-Item Function:\script:Assert-WsmAssistiveFileTopology -Value {param([string]$Path,[switch]$ExactConfig,[string]$SourceRoot='', [string]$RelativePath='')if($script:rejectAssistiveTopologyPath -and [IO.Path]::GetFullPath($Path).Equals([IO.Path]::GetFullPath($script:rejectAssistiveTopologyPath),[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture topology boundary rejection.'};& $script:nativeAssistiveFileTopology -Path $Path -ExactConfig:$ExactConfig -SourceRoot $SourceRoot -RelativePath $RelativePath}
        $script:nativeAssistiveRestoreDecision=(Get-Command Get-WsmAssistiveRestoreDecision -CommandType Function).ScriptBlock
        function Check($condition,[string]$message){if(-not $condition){throw $message};$script:checks++}
        function Reject($Action,[string]$Message){$rejected=$false;try{& $Action}catch{$rejected=$true};Check $rejected $Message}
        $script:checks=0
        $parentOperationId=[Guid]::NewGuid().ToString('D');$differentToken=[pscustomobject]@{OperationId=[Guid]::NewGuid().ToString('D')};Reject {Resolve-WsmAssistiveRestoreParentOperationId $parentOperationId $differentToken -RequireDurableParent} 'Service parent accepted a cancellation token bound to a different TargetRestore operation.'
        Check ((Resolve-WsmAssistiveRestoreParentOperationId $parentOperationId ([pscustomobject]@{OperationId=$parentOperationId}) -RequireDurableParent) -ceq $parentOperationId) 'Explicit TargetRestore parent did not survive cancellation-token binding.'
        Reject {Resolve-WsmAssistiveRestoreParentOperationId '' ([pscustomobject]@{OperationId=$parentOperationId}) -RequireDurableParent} 'A cancellation token created a durable TargetRestore parent without the registered operation id.'
        $nativeOwnerProbe=Join-Path $root 'native-acl-owner-probe';[void][IO.Directory]::CreateDirectory($nativeOwnerProbe);$nativeOwnerFile=Join-Path $nativeOwnerProbe 'probe.txt';[IO.File]::WriteAllText($nativeOwnerFile,'owner getter probe')
        foreach($nativeAclPath in @($nativeOwnerProbe,$nativeOwnerFile)){$nativeAcl=Get-Acl -LiteralPath $nativeAclPath -ErrorAction Stop;Check ($nativeAcl.Owner -is [string]) 'Native Windows Get-Acl Owner is expected to be a string.';$nativeOwnerSid=$nativeAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value;Check ($nativeOwnerSid -match '^S-1-\d+(?:-\d+)+$') 'Native Get-Acl.GetOwner(SecurityIdentifier) did not return a SID.'}
        $script:fixtureMetadata=@{};$script:fixtureMetadataDrift=@{};$script:fixtureUtc='2026-10-10T00:00:00.0000000Z'
        function NewEntry([string]$relative,[string]$content){$bytes=[Text.Encoding]::UTF8.GetBytes($content);[pscustomobject]@{ItemId=$script:testItemId;RelativePath=$relative;Directory=$false;Data=[pscustomobject]@{Hash=(Get-WsmHashText $content);Bytes=$bytes.Length;Content=$content};Metadata=[pscustomobject]@{MetadataMode='DaclOwner';Sddl='';Attributes=0;CreationUtc=$script:fixtureUtc;LastWriteUtc=$script:fixtureUtc}}}
        function NewDirectoryEntry([string]$relative){[pscustomobject]@{ItemId=$script:testItemId;RelativePath=$relative;Directory=$true;Data=$null;Metadata=[pscustomobject]@{MetadataMode='DaclOwner';Sddl='';Attributes=[int][IO.FileAttributes]::Directory;CreationUtc=$script:fixtureUtc;LastWriteUtc=$script:fixtureUtc}}}
        function Read-WsmArtifactLines($Path,$Hash,$CancellationToken){$script:testEntries}
        function Restore-WsmPayloadBytes($Entry,$PackageRoot,$Destination,$CancellationToken){[IO.File]::WriteAllText($Destination,[string]$Entry.Data.Content)}
        function Set-WsmFileMetadata($Path,$Metadata,$SidMap){$key=[IO.Path]::GetFullPath($Path);$script:fixtureMetadata[$key]=$Metadata;if($key -match '\.wsm-[a-f0-9]{32}\.tmp$'){$script:fixtureMetadata[[regex]::Replace($key,'\.wsm-[a-f0-9]{32}\.tmp$','')]=$Metadata}}
        function Get-WsmFileMetadata([string]$Path,[string]$Mode){$key=[IO.Path]::GetFullPath($Path);$metadata=$script:fixtureMetadata[$key];if(-not $metadata){$metadata=[pscustomobject]@{MetadataMode=$Mode;Sddl='';Attributes=0;CreationUtc=$script:fixtureUtc;LastWriteUtc=$script:fixtureUtc}};$actual=$metadata.PSObject.Copy();if($script:fixtureMetadataDrift.ContainsKey($key)){$actual.Sddl='DRIFT'};$actual}
        function Add-WsmJournal($Paths,$State,[string]$Action,[string]$ItemId,$Detail){ }
        function Assert-WsmCancellationBoundary($Token,[string]$Name){ }
        function Assert-WsmSoftwareCatalog($SoftwareCatalog,$SourceInventory){ }
        function Get-WsmAssistiveCurrentSoftwareCatalog($Snapshot){$script:currentSoftwareFixture}
        function Assert-WsmAssistiveContract($Data,[string]$Type){ }
        function Assert-WsmTrustedFile([string]$Path,[string]$ExpectedHash){if((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $ExpectedHash){throw 'Fixture trusted-file hash mismatch.'}}
        function Read-WsmTrustedJson([string]$Path,[string]$ExpectedHash){Assert-WsmTrustedFile $Path $ExpectedHash;Read-WsmJson $Path}

        function Get-WsmGeneralHostSoftwareFactsHash($Entry){Get-WsmHashText ($Entry | ConvertTo-Json -Depth 20 -Compress)}
        $script:testItemId='0123456789abcdef0123456789abcdef'
        $target=Join-Path $root 'existing';[void][IO.Directory]::CreateDirectory($target)
        $external=Join-Path $target 'external.txt';[IO.File]::WriteAllText($external,'operator data')
        $newEntry=NewEntry 'new.txt' 'new payload';$externalEntry=NewEntry 'external.txt' 'package must not replace this'
        $script:testEntries=@($newEntry,$externalEntry)
        $item=[pscustomobject]@{ItemId=$script:testItemId;MigrationSpec=[pscustomobject]@{Adapter='FileScope';TargetPath=$target}}
        $package=[pscustomobject]@{Root=$root;SHA256=('a'*64);Manifest=[pscustomobject]@{Generation=1;ArtifactsHash=('b'*64)}}
        $paths=[pscustomobject]@{Root=$root;State=$null;Journal=$null};$state=[pscustomobject]@{Items=@();PendingOperations=@()}
        $result=Invoke-WsmAssistiveFileScopeRestore $item $package $paths $state @{} $null
        Check ($result.Status -eq 'BlockedConflict') 'External-file collision did not retain a per-file conflict result.'
        Check ([IO.File]::ReadAllText($external) -ceq 'operator data') 'Existing external file was overwritten.'
        Check ([IO.File]::ReadAllText((Join-Path $target 'new.txt')) -ceq 'new payload') 'Independent new file was not placed into the existing directory.'
        Check (@($result.FileResults|Where-Object Status -eq Applied).Count -eq 1) 'Successful child file was lost because a sibling conflicted.'
        $appliedResult=@($result.FileResults|Where-Object Status -eq Applied)[0];Check ($appliedResult.MetadataStatus -ceq 'Verified' -and $result.OwnedFiles[0].MetadataHash -match '^[a-f0-9]{64}$') 'Successful file placement did not persist verified ACL/owner/attribute/timestamp readback evidence.'

        $ownedTarget=Join-Path $root 'owned';[void][IO.Directory]::CreateDirectory($ownedTarget);$ownedPath=Join-Path $ownedTarget 'app.config';[IO.File]::WriteAllText($ownedPath,'old owned bytes')
        $oldHash=(Get-FileHash -LiteralPath $ownedPath -Algorithm SHA256).Hash.ToLowerInvariant();$script:testEntries=@((NewEntry 'app.config' 'new owned bytes'));$priorMetadataHash=Get-WsmAssistiveMetadataHash $script:testEntries[0].Metadata
        $item.MigrationSpec.TargetPath=$ownedTarget;$state.Items=@([pscustomobject]@{ItemId=$script:testItemId;Status='Succeeded';CreatedByTool=$true;AppliedManifestHash=('c'*64);AppliedGeneration=1;OwnedFiles=@([pscustomobject]@{RelativePath='app.config';TargetPath=$ownedPath;SHA256=$oldHash;MetadataHash=$priorMetadataHash;Generation=1});OwnedDirectories=@()});$package.Manifest.Generation=2
        $result=Invoke-WsmAssistiveFileScopeRestore $item $package $paths $state @{} $null
        Check ($result.Status -eq 'Succeeded') 'Verified owned file was not replaced by the next approved generation.'
        Check ([IO.File]::ReadAllText($ownedPath) -ceq 'new owned bytes') 'Approved owned-file update did not read back.'
        Check ($result.OwnedFiles[0].Backup -and [IO.File]::ReadAllText($result.OwnedFiles[0].Backup) -ceq 'old owned bytes') 'Prior owned bytes were not retained for rollback.'
        Check ($result.OwnedFiles[0].MetadataHash -match '^[a-f0-9]{64}$' -and @($result.FileResults|Where-Object {$_.Status -eq 'Applied' -and $_.MetadataStatus -eq 'Verified'}).Count -eq 1) 'Updated owned file did not retain verified native metadata evidence.'

        $exactTarget=Join-Path $root 'exact-programfiles-target';[void][IO.Directory]::CreateDirectory($exactTarget);$exactText='{"site":"fixture"}';$exactArtifact=NewEntry 'appsettings.json' $exactText;$script:testEntries=@($exactArtifact);$exactTargetSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=(Join-Path $root 'exact-source');TargetPath=$exactTarget;ContentSelection='ExactFiles';ConfigFiles=@([pscustomobject]@{RelativePath='appsettings.json';SHA256=(Get-WsmHashText $exactText);Owner='Fixture owner';Evidence='approved config hash'})};$item.MigrationSpec=$exactTargetSpec;$state.Items=@();$package.Manifest.Generation=8
        $aliasTargetRoot=Join-Path $root 'uncreated-protected-target'
        $script:exactTarget=$exactTarget;$script:aliasTargetRoot=$aliasTargetRoot
        $physicalResolver=(Get-Command Get-WsmPhysicalPath -CommandType Function).ScriptBlock
        try{
            Set-Item Function:\script:Get-WsmPhysicalPath -Value {param([string]$Path)$base='\Device\HarddiskVolume123\Program Files\Fixture\Target';$full=[IO.Path]::GetFullPath($Path);$rootPath=[IO.Path]::GetFullPath($script:exactTarget);$aliasRoot=[IO.Path]::GetFullPath($script:aliasTargetRoot);if($full -ieq $rootPath){return $base};if($full.StartsWith($rootPath.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){return ($base+'\'+$full.Substring($rootPath.TrimEnd('\').Length).TrimStart('\'))};if($full -ieq $aliasRoot){return '\Device\HarddiskVolume123\Program Files\Fixture\Alias'};if($full.StartsWith($aliasRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){return ('\Device\HarddiskVolume123\Program Files\Fixture\Alias\'+$full.Substring($aliasRoot.TrimEnd('\').Length).TrimStart('\'))};'\Device\HarddiskVolume123\Users\Fixture\Unrelated'}
            $wholeAliasSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=(Join-Path $root 'whole-source');TargetPath=$aliasTargetRoot;ContentSelection='WholeScope'};$aliasRejected=$false;try{Assert-WsmAssistiveTargetScopeTopology -Path $aliasTargetRoot -Spec $wholeAliasSpec -TargetRoot $aliasTargetRoot -Kind Root}catch{$aliasRejected=$true}
            Check ($aliasRejected -and -not [IO.Directory]::Exists($aliasTargetRoot)) 'WholeScope target root resolving physically into Program Files was not rejected before directory creation.'
            $exactRestore=Invoke-WsmAssistiveFileScopeRestore $item $package $paths $state @{} $null
            Check ($exactRestore.Status -eq 'Succeeded' -and [IO.File]::ReadAllText((Join-Path $exactTarget 'appsettings.json')) -ceq $exactText) 'ExactFiles config restore under a physically protected Program Files path did not complete after artifact, staging and readback checks.'
        }finally{Set-Item Function:\script:Get-WsmPhysicalPath -Value $physicalResolver}

        $directoryTarget=Join-Path $root 'directory-metadata';$script:testEntries=@((NewDirectoryEntry ''),(NewDirectoryEntry 'nested'),(NewEntry 'nested\settings.ini' 'directory payload'));$item.MigrationSpec.ContentSelection='WholeScope';$item.MigrationSpec.ConfigFiles=@();$item.MigrationSpec.TargetPath=$directoryTarget;$state.Items=@();$package.Manifest.Generation=3
        $directoryResult=Invoke-WsmAssistiveFileScopeRestore $item $package $paths $state @{} $null
        Check ($directoryResult.Status -eq 'Succeeded' -and (Test-Path -LiteralPath (Join-Path $directoryTarget 'nested\settings.ini'))) 'New native directory tree was not completely restored.'
        Check (@($directoryResult.OwnedDirectories|Where-Object {$_.RelativePath -ceq '' -and $_.TargetPath -ceq $directoryTarget -and $_.MetadataHash -match '^[a-f0-9]{64}$'}).Count -eq 1 -and @($directoryResult.OwnedDirectories|Where-Object {$_.RelativePath -ceq 'nested' -and $_.MetadataHash -match '^[a-f0-9]{64}$'}).Count -eq 1) 'New root/nested directories lack verified metadata ownership evidence.'
        Check (@($directoryResult.FileResults|Where-Object {$_.Status -eq 'DirectoryVerified' -and $_.MetadataStatus -eq 'Verified'}).Count -eq 2) 'Directory ACL/owner/attribute/timestamp metadata was not applied and read back.'
        $script:rejectAssistiveTopologyPath=$directoryTarget;$directoryTopologyRejected=$false;try{Invoke-WsmAssistiveFileScopeRestore $item $package $paths $state @{} $null|Out-Null}catch{$directoryTopologyRejected=$true};$script:rejectAssistiveTopologyPath=''
        Check ($directoryTopologyRejected -and (Test-Path -LiteralPath (Join-Path $directoryTarget 'nested\settings.ini'))) 'Existing directory target topology failure did not fail closed before G writes.'

        $nestedConfigText='nested exact configuration';$nestedConfigHash=Get-WsmHashText $nestedConfigText;$item.MigrationSpec=[pscustomobject]@{Adapter='FileScope';TransferChannel='C';SourcePath=(Join-Path $root 'nested-config-source');TargetPath=$exactTarget;ContentSelection='ExactFiles';Metadata='DaclOwner';ConfigFiles=@([pscustomobject]@{RelativePath='sub\settings.ini';SHA256=$nestedConfigHash;Owner='Fixture owner';Evidence='reviewed nested config hash'})};$script:testEntries=@((NewDirectoryEntry ''),(NewDirectoryEntry 'sub'),(NewEntry 'sub\settings.ini' $nestedConfigText));$package.Manifest.Generation=9;$state.Items=@()
        $nestedExactRestore=Invoke-WsmAssistiveFileScopeRestore $item $package $paths $state @{} $null;$state.Items=@($nestedExactRestore)
        Check ($nestedExactRestore.Status -eq 'Succeeded' -and [IO.File]::ReadAllText((Join-Path $exactTarget 'sub\settings.ini')) -ceq $nestedConfigText) 'A hash-bound nested ExactFiles config did not restore under the isolated physical Program Files observation.'
        $stagePlanItems=@{};$stagePlanItems[$script:testItemId]=$item;$stageFileRows=@(Get-WsmAssistiveStageFileResultRows $package $state @($script:testItemId) $stagePlanItems);$nestedStageFile=@($stageFileRows|Where-Object RelativePath -CEQ 'sub\settings.ini')
        Check ($nestedStageFile.Count -eq 1 -and $nestedStageFile[0].Status -ceq 'Applied' -and $nestedStageFile[0].EffectivePath -ieq (Join-Path $exactTarget 'sub\settings.ini')) 'Final C FileScope result projection deferred a current-generation nested ExactFiles config readback.'

        $singleParent=Join-Path $root 'single-file-parent';$singleTarget=Join-Path $singleParent 'settings.ini';$script:testEntries=@((NewEntry '' 'single-file payload'));$item.MigrationSpec.ContentSelection='WholeScope';$item.MigrationSpec.ConfigFiles=@();$item.MigrationSpec.TargetPath=$singleTarget;$state.Items=@();$package.Manifest.Generation=4
        $singleResult=Invoke-WsmAssistiveFileScopeRestore $item $package $paths $state @{} $null
        Check ([IO.File]::Exists($singleTarget) -and -not [IO.Directory]::Exists($singleTarget) -and [IO.File]::ReadAllText($singleTarget) -ceq 'single-file payload') 'Single-file source scope was not restored to its exact TargetPath file.'
        Check (@($singleResult.OwnedFiles|Where-Object {$_.RelativePath -ceq '' -and $_.TargetPath -ceq $singleTarget -and $_.MetadataHash -match '^[a-f0-9]{64}$'}).Count -eq 1 -and @($singleResult.OwnedDirectories).Count -eq 0) 'Single-file ownership was not recorded against the exact file target.'
        $state.Items=@($singleResult);$package.Manifest.Generation=5;$singleVerify=Invoke-WsmAssistiveFileScopeRestore $item $package $paths $state @{} $null
        Check (@($singleVerify.FileResults|Where-Object Status -eq VerifiedOwned).Count -eq 1 -and -not $singleVerify.OwnedFiles[0].Backup) 'Owned single-file rerun was not verified without a needless replacement.'
        $script:fixtureMetadataDrift[[IO.Path]::GetFullPath($singleTarget)]=$true;$state.Items=@($singleResult);$singleDrift=Invoke-WsmAssistiveFileScopeRestore $item $package $paths $state @{} $null
        Check ($singleDrift.Status -eq 'BlockedConflict' -and [IO.File]::ReadAllText($singleTarget) -ceq 'single-file payload' -and $singleDrift.OwnedFiles[0].Generation -eq 5) 'VerifiedOwned accepted metadata drift or advanced its ownership generation.'
        $script:fixtureMetadataDrift.Remove([IO.Path]::GetFullPath($singleTarget))
        $singleExternal=Join-Path $root 'single-file-external.ini';[IO.File]::WriteAllText($singleExternal,'operator-owned');$item.MigrationSpec.TargetPath=$singleExternal;$state.Items=@();$singleCollision=Invoke-WsmAssistiveFileScopeRestore $item $package $paths $state @{} $null
        Check ($singleCollision.Status -eq 'BlockedConflict' -and [IO.File]::ReadAllText($singleExternal) -ceq 'operator-owned') 'External file at an exact single-file destination was overwritten.'
        $singleReplacement='replacement payload';$script:testEntries=@((NewEntry '' $singleReplacement));$item.MigrationSpec.TargetPath=$singleTarget;$state.Items=@($singleVerify);$package.Manifest.Generation=6;$script:rejectAssistiveTopologyPath=$singleTarget;$singleTopologyRejected=$false;try{Invoke-WsmAssistiveFileScopeRestore $item $package $paths $state @{} $null|Out-Null}catch{$singleTopologyRejected=$true};$script:rejectAssistiveTopologyPath=''
        Check ($singleTopologyRejected -and [IO.File]::ReadAllText($singleTarget) -ceq 'single-file payload' -and @($state.PendingOperations).Count -eq 0) 'Existing owned single-file topology failure did not block replacement before intent or preserve prior bytes.'
        $state.Items=@($singleResult);$singleUpdate=Invoke-WsmAssistiveFileScopeRestore $item $package $paths $state @{} $null
        Check ([IO.File]::ReadAllText($singleTarget) -ceq $singleReplacement -and $singleUpdate.OwnedFiles[0].Backup -and [IO.File]::ReadAllText($singleUpdate.OwnedFiles[0].Backup) -ceq 'single-file payload') 'Owned single-file generation update did not retain exact prior bytes for rollback.'

        $driftTarget=Join-Path $root 'metadata-drift';[void][IO.Directory]::CreateDirectory($driftTarget);$driftFile=Join-Path $driftTarget 'drift.txt';$script:testEntries=@((NewEntry 'drift.txt' 'drift payload'));$script:fixtureMetadataDrift[[IO.Path]::GetFullPath($driftFile)]=$true;$item.MigrationSpec.TargetPath=$driftTarget;$state.Items=@();$package.Manifest.Generation=4
        $driftResult=Invoke-WsmAssistiveFileScopeRestore $item $package $paths $state @{} $null
        Check ($driftResult.Status -eq 'Failed' -and @($driftResult.FileResults|Where-Object {$_.Status -eq 'Failed' -and $_.MetadataStatus -ne 'Verified'}).Count -eq 1 -and @($state.PendingOperations|Where-Object RelativePath -eq 'drift.txt').Count -eq 1) 'Metadata drift after file replacement was adopted without repair intent.'

        [IO.File]::WriteAllText($ownedPath,'operator drift')
        $result=Invoke-WsmAssistiveFileScopeRestore $item $package $paths $state @{} $null
        Check ($result.Status -eq 'BlockedConflict') 'Drifted owned file was silently replaced.'
        Check ([IO.File]::ReadAllText($ownedPath) -ceq 'operator drift') 'Drifted owned file was overwritten.'

        $doc=Read-WsmXml '<rules><rule name="legacy" enabled="true" /></rules>'
        $changes=@([pscustomobject]@{Operation='SetAttribute';FieldPointer="/rules/rule[@name='legacy']/@enabled";ElementName='rule';AttributeName='enabled';BeforeValue='true';AfterValue='false';KeyAttributes=@()})
        $mapped=Set-WsmIisConfigChanges $doc $changes
        Check ($mapped.SelectSingleNode('/rules/rule').GetAttribute('enabled') -ceq 'false') 'Typed IIS pointer did not apply the selected attribute change.'
        $opaque=[pscustomobject]@{MigrationSpec=[pscustomobject]@{Adapter='IISLocation';SourceXml='<rules />';SourceAutoStart='Unknown';StagedDisabled=$true;DesiredFinalState='Disabled';WorkloadMappingReview=@([pscustomobject]@{FieldPointer='/rules/rule/@command';OldRawValue='tool --password SuperSecretValue';TargetValue='';Applied=$false;Status='Opaque';ReviewRequired=$true;Reason='Command contains opaque arguments.'})}}
        $readiness=Get-WsmAssistiveWorkloadReadiness $opaque
        Check ($readiness.Status -eq 'ManualEvidenceRequired') 'Opaque command argument did not require manual owner review.'
        Check ($readiness.Reason -notmatch 'SuperSecretValue|password') 'Safe readiness projection leaked opaque command-line material.'

        $taskSource='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Settings><Enabled>false</Enabled></Settings><Actions><Exec><Command>C:\Fixture\worker.exe</Command></Exec></Actions></Task>'
        $taskTarget=$taskSource.Replace('<Enabled>false</Enabled>','<Enabled>false</Enabled>')
        $taskSpec=[pscustomobject]@{Adapter='ScheduledTask';SourceXml=$taskSource;SourceAutoStart='false';StagedDisabled=$true;DesiredFinalState='Disabled';ActivationPolicyFieldPointer='Task/Settings/Enabled';ReviewedActivation=[pscustomobject]@{FinalState='Disabled';Owner='Fixture owner';Reason='Keep task stopped pending acceptance.';SourceAutoStart='false';FieldPointer='Task/Settings/Enabled'};Desired=[pscustomobject]@{Xml=$taskTarget}}
        Assert-WsmAssistiveReviewedActivation $taskSpec
        Check $true 'Explicit disabled activation intent was rejected.'
        $taskSpec.ReviewedActivation.FinalState='Enabled';$taskSpec.DesiredFinalState='Enabled';$taskSpec.ReviewedActivation.Reason='Enable after business acceptance.'
        $rejected=$false;try{Assert-WsmAssistiveReviewedActivation $taskSpec|Out-Null}catch{$rejected=$true}
        Check $rejected 'Source-disabled task was enabled without an owner reason acknowledging the changed source policy.'
        $taskSpec.ReviewedActivation.Reason='Owner approves enabling despite source task being disabled.'
        Assert-WsmAssistiveReviewedActivation $taskSpec
        Check $true 'Explicit owner-approved activation from source-disabled policy was rejected.'
        $sourceDisabledReason=([string][char]0x8CA0)+[char]0x8CAC+[char]0x4EBA+[char]0x6838+[char]0x51C6+[char]0xFF0C+[char]0x5373+[char]0x4F7F+[char]0x4F86+[char]0x6E90+[char]0x5DE5+[char]0x4F5C+[char]0x5DF2+[char]0x505C+[char]0x7528+[char]0xFF0C+[char]0x9A57+[char]0x6536+[char]0x5F8C+[char]0x4ECD+[char]0x555F+[char]0x7528+[char]0x3002
        $taskSpec.ReviewedActivation.Reason=$sourceDisabledReason
        Assert-WsmAssistiveReviewedActivation $taskSpec
        Check $true 'Unicode owner reason acknowledging the source-disabled policy was rejected.'
        $taskSpec.SourceXml=$taskSource.Replace('<Enabled>false</Enabled>','<Enabled>true</Enabled>');$taskSpec.SourceAutoStart='true';$taskSpec.ReviewedActivation.SourceAutoStart='true';$taskSpec.ReviewedActivation.Reason='Preserve approved source startup policy.'
        Assert-WsmAssistiveReviewedActivation $taskSpec
        Check $true 'Enabled activation matching the protected source startup policy was rejected.'

        $iisSource='<rules><rule name="legacy" enabled="true" path="C:\\source" /></rules>';$iisStaged='<rules><rule name="legacy" enabled="false" path="C:\\target" /></rules>'
        $iisSpec=[pscustomobject]@{Adapter='IISSection';SourceXml=$iisSource;SourceAutoStart='true';StagedDisabled=$true;DesiredFinalState='Enabled';ActivationPolicyFieldPointer="/rules/rule[@name='legacy']/@enabled";ReviewedActivation=[pscustomobject]@{FinalState='Enabled';Owner='Fixture owner';Reason='Preserve the explicitly approved source startup behavior.';SourceAutoStart='true';FieldPointer="/rules/rule[@name='legacy']/@enabled";StagedValue='false';FinalValue='true'};Desired=[pscustomobject]@{SectionPath='system.webServer/rewrite/rules';LocationPath='';Xml=$iisStaged;Changes=@()}}
        Assert-WsmAssistiveReviewedActivation $iisSpec
        $iisFinalXml=Get-WsmIisReviewedActivationXml $iisSpec;$iisFinalDoc=Read-WsmXml $iisFinalXml
        Check ($iisFinalDoc.DocumentElement.FirstChild.GetAttribute('enabled') -ceq 'true' -and $iisFinalDoc.DocumentElement.FirstChild.GetAttribute('path') -ceq 'C:\\target') 'IIS config final intent changed an unreviewed sibling attribute or failed to apply its one approved field.'
        $iisSpec.ReviewedActivation.FinalValue='AlwaysRunning';$iisSpec.DesiredFinalState='Enabled';$iisSpec.ReviewedActivation.FieldPointer="/rules/rule[@name='legacy']/@enabled"
        $iisInvalidValue=$false;try{Assert-WsmAssistiveReviewedActivation $iisSpec|Out-Null}catch{$iisInvalidValue=$true}
        Check $iisInvalidValue 'IIS config activation accepted a final value outside the typed activation field domain.'

        $softwareEntry=[pscustomobject]@{SoftwareId='sw-fixture';Name='Fixture Runtime';Version='1.2.3';Publisher='Fixture';Architecture='x64';Scope='Machine';SID='';RegistryView='Registry64';Location='C:\Fixture\runtime';SourceKind='Registry';Evidence=[pscustomobject]@{RegistryPath='fixture';NaturalKey='fixture'};CaptureStatus='Success';ItemIds=@();AccountContext='Unknown'}
        $softwareCatalog=[pscustomobject]@{Entries=@($softwareEntry);Coverage=@([pscustomobject]@{Probe='ProfileList';Scope='User';SID='S-1-5-21-fixture';View='Registry64';Status='PermissionDenied';EvidenceKind='Registry';Count=0;ErrorKind='AccessDenied';ItemId=''})};$softwareSnapshot=[pscustomobject]@{SoftwareCatalog=$softwareCatalog};$script:currentSoftwareFixture=$softwareCatalog
        $softwareCheck=Assert-WsmAssistiveCurrentSoftware $softwareSnapshot
        Check ($softwareCheck.Status -eq 'Match' -and $softwareCheck.Coverage -eq 'Incomplete' -and $softwareCheck.CoverageGapCount -eq 1 -and $softwareCheck.ProductionVerified -eq $false) 'Stable incomplete profile coverage globally blocked an unrelated restore or was reported complete.'
        $profileGap=[pscustomobject]@{ConsumerItemId='runtime-item';Issue='Required runtime was not observed because profile coverage is incomplete.'};$fileDependencyIssues=Get-WsmAssistiveItemDependencyIssues @($profileGap) $script:testItemId;$runtimeDependencyIssues=Get-WsmAssistiveItemDependencyIssues @($profileGap) 'runtime-item'
        Check (@($fileDependencyIssues).Count -eq 0 -and @($runtimeDependencyIssues).Count -eq 1) 'An incomplete profile/portable probe did not stay scoped to its affected runtime consumer.'
        $dependencyPackage=[pscustomobject]@{Plan=[pscustomobject]@{Items=@([pscustomobject]@{ItemId='runtime-item'},[pscustomobject]@{ItemId=$script:testItemId});GeneralHost=[pscustomobject]@{Requirements=@([pscustomobject]@{RequirementId='req-fixture';ProviderSoftwareId='sw-fixture';ConsumerItemIds=@('runtime-item');Certainty='Required';Decision='Required'})}}}
        $dependencyDecision=[pscustomobject]@{SelectedItemIds=@('runtime-item');Receipt=[pscustomobject]@{Comparison=[pscustomobject]@{Rows=@([pscustomobject]@{SoftwareId='sw-fixture';SourceVersion='1.2.3';ChosenVersion='2.0.0';ObservedTargetVersion='2.0.0';SourceCaptureStatus='Success';TargetCaptureStatus='Success';SourceVersionEvidenceKind='Registry|Probe:Uninstall';TargetVersionEvidenceKind='Registry|Probe:Uninstall';Status='ChosenVersionObserved'})}}}
        $chosenIssues=Get-WsmAssistiveComparisonDependencyIssues $dependencyPackage $dependencyDecision
        Check (@($chosenIssues).Count -eq 0) 'A newer chosen version observed on the target was not accepted as the current dependency expectation.'
        $dependencyDecision.Receipt.Comparison.Rows[0].TargetCaptureStatus='Partial';$partialTargetIssues=Get-WsmAssistiveComparisonDependencyIssues $dependencyPackage $dependencyDecision
        Check (@($partialTargetIssues | Where-Object ConsumerItemId -CEQ 'runtime-item').Count -eq 1) 'A positive status from a partial target capture satisfied a required workload dependency.'
        $dependencyDecision.Receipt.Comparison.Rows[0].TargetCaptureStatus='Success'
        $dependencyDecision.Receipt.Comparison.Rows[0].ObservedTargetVersion='1.2.3';$dependencyDecision.Receipt.Comparison.Rows[0].Status='DifferentFromChosenVersion';$differentIssues=Get-WsmAssistiveComparisonDependencyIssues $dependencyPackage $dependencyDecision
        Check (@($differentIssues | Where-Object ConsumerItemId -CEQ 'runtime-item').Count -eq 1 -and @($differentIssues | Where-Object ConsumerItemId -CEQ $script:testItemId).Count -eq 0) 'An outdated chosen dependency blocked an independent FileScope item or failed to defer its own consumer.'
        $dependencyDecision.Receipt.Comparison.Rows=@();$missingIssues=Get-WsmAssistiveComparisonDependencyIssues $dependencyPackage $dependencyDecision
        Check (@($missingIssues | Where-Object ConsumerItemId -CEQ 'runtime-item').Count -eq 1) 'Missing chosen-version evidence did not remain scoped to the dependent item.'
        $peerTargetRoot=Join-Path $root 'approved-peer-target';[void][IO.Directory]::CreateDirectory($peerTargetRoot);$peerTargetPhysicalRoot=Get-WsmPhysicalPath $peerTargetRoot
        $targetPeer=[pscustomobject]@{PeerName='fixture-target';ShareName='data';LocalPhysicalRoot=$peerTargetPhysicalRoot;PeerFingerprint=('b'*64)};$targetPhysicalProof=[pscustomobject]@{PeerShareProofs=@($targetPeer)}
        $nativePackage=[pscustomobject]@{Plan=[pscustomobject]@{Items=@([pscustomobject]@{ItemId=$script:testItemId;MigrationSpec=[pscustomobject]@{Adapter='FileScope';TransferChannel='NonC';TargetPath=$peerTargetRoot;ContentSelection='ExactFiles'}})}}
        $nativeEntry=[pscustomobject]@{ItemId=$script:testItemId;EntryType='File';RelativePath='app\worker.dll';TargetPath='\\fixture-target\data\app\worker.dll';TargetPhysicalIdentity=(Get-WsmAssistiveEndpointIdentity '\\fixture-target\data\app\worker.dll' @($targetPeer))};$nativePath=Get-WsmAssistiveNonCTargetNativePath $nativePackage $nativeEntry @($nativeEntry) $targetPhysicalProof
        Check ($nativePath -ceq (Join-Path $peerTargetRoot 'app\worker.dll')) 'Exact-file NonC destination did not resolve from the sealed native target and relative path.'
        $nativeProjection=ConvertTo-WsmAssistiveNonCFileResultRows $script:testItemId @([pscustomobject]@{EntryId=('a'*64);RelativePath='app\worker.dll';EntryType='File';Status='Applied';TargetPath=$nativePath;OriginalSourcePath='\\source\share\worker.dll';SHA256=('a'*64);SourceSHA256=('a'*64);Reason='';Generation=2})
        Check ($nativeProjection[0].PreservedPath -ceq $nativePath -and $nativeProjection[0].OriginalPath -ceq '\\source\share\worker.dll' -and $nativeProjection[0].EffectivePath -ceq $nativePath) 'NonC file projection confused the UNC source path with the native target preservation/effective path.'
        $deferredProjection=ConvertTo-WsmAssistiveNonCFileResultRows $script:testItemId @([pscustomobject]@{EntryId=('b'*64);RelativePath='app\worker.dll';EntryType='File';Status='Deferred';TargetPath=$nativePath;OriginalSourcePath='\\source\share\worker.dll';SHA256='';SourceSHA256=('a'*64);Reason='No readback';Generation=2})
        Check (-not $deferredProjection[0].EffectivePath) 'A NonC row without native target readback exposed an EffectivePath.'
        $nativeEntry.TargetPath='\\source\share\worker.dll';$sourcePathRejected=$false;try{Get-WsmAssistiveNonCTargetNativePath $nativePackage $nativeEntry @($nativeEntry) $targetPhysicalProof|Out-Null}catch{$sourcePathRejected=$true}
        Check $sourcePathRejected 'A source UNC path was accepted as the sealed target native destination.'
        $script:currentSoftwareFixture=[pscustomobject]@{Entries=@($softwareEntry);Coverage=@([pscustomobject]@{Probe='ProfileList';Scope='User';SID='S-1-5-21-fixture';View='Registry64';Status='Success';EvidenceKind='Registry';Count=0;ErrorKind='';ItemId=''})};$coverageDriftRejected=$false;try{Assert-WsmAssistiveCurrentSoftware $softwareSnapshot|Out-Null}catch{$coverageDriftRejected=$true}
        Check $coverageDriftRejected 'A changed target software coverage vector reused the prior decision receipt.'
        $script:currentSoftwareFixture=[pscustomobject]@{Entries=@([pscustomobject]@{SoftwareId='sw-fixture';Name='Fixture Runtime';Version='9.9.9';Publisher='Fixture';Architecture='x64';Scope='Machine';SID='';RegistryView='Registry64';Location='C:\Fixture\runtime';SourceKind='Registry';Evidence=[pscustomobject]@{RegistryPath='fixture';NaturalKey='fixture'};CaptureStatus='Success';ItemIds=@();AccountContext='Unknown'});Coverage=@([pscustomobject]@{Status='Success'})}
        $driftRejected=$false;try{Assert-WsmAssistiveCurrentSoftware $softwareSnapshot|Out-Null}catch{$driftRejected=$true}
        Check $driftRejected 'Changed target software version passed the decision freshness gate.'

        # Schema 3 decision evidence must carry the exact comparison and prove
        # that each observed version came from the fingerprinted target snapshot.
        $identity=('9'*64);$targetSnapshot=[pscustomobject]@{CreatedUtc=[DateTime]::UtcNow.ToString('o');Source=[pscustomobject]@{Fingerprint=$identity};SoftwareCatalog=$softwareCatalog}
        $snapshotPath=Join-Path $root 'decision-snapshot.json';Write-WsmJson $snapshotPath $targetSnapshot;$snapshotHash=(Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $comparison=[pscustomobject][ordered]@{Revision=7;SourceSnapshotHash=('1'*64);TargetSnapshotHash=$snapshotHash;SelectionRevision=3;Rows=@([pscustomobject][ordered]@{SoftwareId='sw-fixture';SourceVersion='1.2.3';ChosenVersion='2.0.0';ObservedTargetVersion='1.2.3';TargetSoftwareId='sw-fixture';Status='DifferentFromChosenVersion'})}
        $plan=[pscustomobject]@{SchemaVersion=3;Kind='MigrationPlan';PairId='pair-fixture';Assistive=[pscustomobject]@{SourceSnapshotHash=('1'*64);ApprovedItemIds=@($script:testItemId)};Items=@([pscustomobject]@{ItemId=$script:testItemId})}
        $decisionPackage=[pscustomobject]@{SHA256=('2'*64);PlanHash=('3'*64);Plan=$plan;Manifest=[pscustomobject]@{PairId='pair-fixture';PlanHash=('3'*64);Generation=5;Target=[pscustomobject]@{Fingerprint=$identity}}}
        $receipt=[pscustomobject][ordered]@{SchemaVersion=1;Kind='AssistiveTargetDecisionReceipt';ReceiptId='fixture';PairId='pair-fixture';PlanHash=('3'*64);ManifestHash=('2'*64);Generation=5;TargetSnapshotHash=$snapshotHash;ComparisonRevision=7;SelectionRevision=3;Decision='RestoreNow';Owner='Fixture owner';Reason='Exercise exact restore evidence';SelectedItemIds=@($script:testItemId);AcceptedUnpreparedItemIds=@();CreatedUtc=[DateTime]::UtcNow.ToString('o');Comparison=$comparison;ComparisonHash=(Get-WsmHashText ($comparison | ConvertTo-Json -Depth 100 -Compress));SHA256=('4'*64)}
        $receiptPath=Join-Path $root 'decision-receipt.json';Write-WsmJson $receiptPath $receipt;$receiptHash=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:currentSoftwareFixture=$softwareCatalog
        $accepted=Get-WsmAssistiveRestoreDecision $decisionPackage $decisionPackage.SHA256 $receiptPath $receiptHash $snapshotPath
        Check (@($accepted.SelectedItemIds).Count -eq 1 -and $accepted.Receipt.Comparison.Rows[0].ChosenVersion -ceq '2.0.0') 'A newer explicitly chosen version with exact observed snapshot evidence was not preserved through restore decision validation.'
        $partialSoftwareCatalog=ConvertFrom-WsmJson ($softwareCatalog|ConvertTo-Json -Depth 30);$partialSoftwareCatalog.Entries[0].Version='2.0.0';$partialSoftwareCatalog.Entries[0].CaptureStatus='Partial'
        $partialTargetSnapshot=[pscustomobject]@{CreatedUtc=[DateTime]::UtcNow.ToString('o');Source=[pscustomobject]@{Fingerprint=$identity};SoftwareCatalog=$partialSoftwareCatalog};$partialSnapshotPath=Join-Path $root 'decision-snapshot-partial.json';Write-WsmJson $partialSnapshotPath $partialTargetSnapshot;$partialSnapshotHash=(Get-FileHash -LiteralPath $partialSnapshotPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $partialObservedComparison=[pscustomobject][ordered]@{Revision=8;SourceSnapshotHash=('1'*64);TargetSnapshotHash=$partialSnapshotHash;SelectionRevision=3;Rows=@([pscustomobject][ordered]@{SoftwareId='sw-fixture';SourceVersion='1.2.3';ChosenVersion='2.0.0';ObservedTargetVersion='2.0.0';TargetSoftwareId='sw-fixture';Status='ChosenVersionObserved'})}
        $partialReceipt=$receipt.PSObject.Copy();$partialReceipt.TargetSnapshotHash=$partialSnapshotHash;$partialReceipt.ComparisonRevision=8;$partialReceipt.Comparison=$partialObservedComparison;$partialReceipt.ComparisonHash=Get-WsmHashText ($partialObservedComparison|ConvertTo-Json -Depth 100 -Compress);$script:currentSoftwareFixture=$partialSoftwareCatalog
        Write-WsmJson $snapshotPath $partialTargetSnapshot;Write-WsmJson $receiptPath $partialReceipt;$partialReceiptHash=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $partialRestoreRejected=$false;try{Get-WsmAssistiveRestoreDecision $decisionPackage $decisionPackage.SHA256 $receiptPath $partialReceiptHash $snapshotPath|Out-Null}catch{$partialRestoreRejected=$true}
        Check $partialRestoreRejected 'Real receipt→snapshot validation accepted a legacy positive row backed by a partial target software capture.'
        $targetObservedCatalog=ConvertFrom-WsmJson ($softwareCatalog|ConvertTo-Json -Depth 30);$targetObservedCatalog.Entries[0].Version='2.0.0'
        $sourceEvidenceEntry=ConvertFrom-WsmJson ($softwareEntry|ConvertTo-Json -Depth 20);$sourceEvidenceEntry.Evidence=[pscustomobject]@{Probe='FileVersion'};$sourceEvidenceEntry.Version='1.2.3';$sourceEvidenceEntry.CaptureStatus='Partial'
        $sourceBoundPackage=$decisionPackage.PSObject.Copy();$sourceBoundPackage.Plan=$plan.PSObject.Copy();$sourceBoundPackage.Plan|Add-Member NoteProperty GeneralHost ([pscustomobject]@{SoftwareCatalog=[pscustomobject]@{Entries=@($sourceEvidenceEntry)}}) -Force
        $targetObservedSnapshot=[pscustomobject]@{CreatedUtc=[DateTime]::UtcNow.ToString('o');Source=[pscustomobject]@{Fingerprint=$identity};SoftwareCatalog=$targetObservedCatalog};Write-WsmJson $snapshotPath $targetObservedSnapshot;$targetObservedHash=(Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $legacyPositiveComparison=[pscustomobject][ordered]@{Revision=9;SourceSnapshotHash=('1'*64);TargetSnapshotHash=$targetObservedHash;SelectionRevision=3;Rows=@([pscustomobject][ordered]@{SoftwareId='sw-fixture';SourceVersion='1.2.3';ChosenVersion='2.0.0';ObservedTargetVersion='2.0.0';TargetSoftwareId='sw-fixture';Status='ChosenVersionObserved'})}
        $legacyPositiveReceipt=$receipt.PSObject.Copy();$legacyPositiveReceipt.TargetSnapshotHash=$targetObservedHash;$legacyPositiveReceipt.ComparisonRevision=9;$legacyPositiveReceipt.Comparison=$legacyPositiveComparison;$legacyPositiveReceipt.ComparisonHash=Get-WsmHashText ($legacyPositiveComparison|ConvertTo-Json -Depth 100 -Compress);Write-WsmJson $receiptPath $legacyPositiveReceipt;$legacyPositiveHash=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant();$script:currentSoftwareFixture=$targetObservedCatalog
        $partialSourceRejected=$false;try{Get-WsmAssistiveRestoreDecision $sourceBoundPackage $sourceBoundPackage.SHA256 $receiptPath $legacyPositiveHash $snapshotPath|Out-Null}catch{$partialSourceRejected=$true}
        Check $partialSourceRejected 'A legacy positive receipt omitted source capture status and passed despite its exact sealed source row being partial.'
        $sourceEvidenceEntry.CaptureStatus='Success'
        $sourceProvenanceRejected=$false;try{Get-WsmAssistiveRestoreDecision $sourceBoundPackage $sourceBoundPackage.SHA256 $receiptPath $legacyPositiveHash $snapshotPath|Out-Null}catch{$sourceProvenanceRejected=$true}
        Check $sourceProvenanceRejected 'A legacy positive receipt omitted version provenance and passed despite different raw source and target version evidence kinds.'
        $script:currentSoftwareFixture=$softwareCatalog
        $bindingPackage=$decisionPackage.PSObject.Copy();$bindingPackage.Plan=$plan.PSObject.Copy();$bindingPackage.Plan | Add-Member NoteProperty GeneralHost ([pscustomobject]@{SoftwareCatalog=[pscustomobject]@{Entries=@([pscustomobject]@{SoftwareId='sw-fixture';Version='1.2.3'})}}) -Force
        $goodObservedComparison=$comparison.PSObject.Copy();$goodObservedComparison.Rows=@($comparison.Rows[0].PSObject.Copy());$goodObservedComparison.Rows[0].Status='ChosenVersionObserved';$goodObservedComparison.Rows[0].ObservedTargetVersion='2.0.0';$receipt.Comparison=$goodObservedComparison;$receipt.ComparisonHash=Get-WsmHashText ($goodObservedComparison|ConvertTo-Json -Depth 100 -Compress)
        $bindingResult=Assert-WsmAssistiveReceiptComparisonBinding $bindingPackage $receipt
        Check $bindingResult 'A comparison with exact chosen/observed equality and sealed source version was rejected.'
        $badDifferentComparison=$goodObservedComparison.PSObject.Copy();$badDifferentComparison.Rows=@($goodObservedComparison.Rows[0].PSObject.Copy());$badDifferentComparison.Rows[0].Status='DifferentFromChosenVersion';$receipt.Comparison=$badDifferentComparison;$receipt.ComparisonHash=Get-WsmHashText ($badDifferentComparison|ConvertTo-Json -Depth 100 -Compress)
        $statusMismatchRejected=$false;try{Assert-WsmAssistiveReceiptComparisonBinding $bindingPackage $receipt|Out-Null}catch{$statusMismatchRejected=$true}
        Check $statusMismatchRejected 'DifferentFromChosenVersion accepted equal chosen and observed versions.'
        $badChosenComparison=$goodObservedComparison.PSObject.Copy();$badChosenComparison.Rows=@($goodObservedComparison.Rows[0].PSObject.Copy());$badChosenComparison.Rows[0].ChosenVersion='3.0.0';$receipt.Comparison=$badChosenComparison;$receipt.ComparisonHash=Get-WsmHashText ($badChosenComparison|ConvertTo-Json -Depth 100 -Compress)
        $chosenMismatchRejected=$false;try{Assert-WsmAssistiveReceiptComparisonBinding $bindingPackage $receipt|Out-Null}catch{$chosenMismatchRejected=$true}
        Check $chosenMismatchRejected 'ChosenVersionObserved accepted unequal chosen and observed versions.'
        $badSourceComparison=$goodObservedComparison.PSObject.Copy();$badSourceComparison.Rows=@($goodObservedComparison.Rows[0].PSObject.Copy());$badSourceComparison.Rows[0].SourceVersion='8.8.8';$receipt.Comparison=$badSourceComparison;$receipt.ComparisonHash=Get-WsmHashText ($badSourceComparison|ConvertTo-Json -Depth 100 -Compress)
        $sourceVersionMismatchRejected=$false;try{Assert-WsmAssistiveReceiptComparisonBinding $bindingPackage $receipt|Out-Null}catch{$sourceVersionMismatchRejected=$true}
        Check $sourceVersionMismatchRejected 'Comparison SourceVersion differing from the sealed GeneralHost catalog was accepted.'
        $receipt.Comparison=$comparison;$receipt.ComparisonHash=Get-WsmHashText ($comparison|ConvertTo-Json -Depth 100 -Compress)
        $missingComparison=$receipt.PSObject.Copy();$missingComparison.PSObject.Properties.Remove('Comparison');Write-WsmJson $receiptPath $missingComparison;$receiptHash=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant();$missingRejected=$false;try{Get-WsmAssistiveRestoreDecision $decisionPackage $decisionPackage.SHA256 $receiptPath $receiptHash $snapshotPath|Out-Null}catch{$missingRejected=$true}
        Check $missingRejected 'Schema 3 restore accepted a decision receipt without embedded comparison evidence.'
        $tampered=$receipt.PSObject.Copy();$tampered.Owner='Changed after approval';Write-WsmJson $receiptPath $tampered;$tamperRejected=$false;try{Get-WsmAssistiveRestoreDecision $decisionPackage $decisionPackage.SHA256 $receiptPath $receiptHash $snapshotPath|Out-Null}catch{$tamperRejected=$true}
        Check $tamperRejected 'Receipt content changed after approval but the prior trusted hash still passed.'
        $badComparison=$comparison.PSObject.Copy();$badComparison.SourceSnapshotHash=('5'*64);$receipt.Comparison=$badComparison;$receipt.ComparisonHash=(Get-WsmHashText ($badComparison|ConvertTo-Json -Depth 100 -Compress));Write-WsmJson $receiptPath $receipt;$receiptHash=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant();$sourceBindingRejected=$false;try{Get-WsmAssistiveRestoreDecision $decisionPackage $decisionPackage.SHA256 $receiptPath $receiptHash $snapshotPath|Out-Null}catch{$sourceBindingRejected=$true}
        Check $sourceBindingRejected 'Restore accepted comparison evidence from a different sealed source snapshot.'
        $wrongObserved=$comparison.PSObject.Copy();$wrongObserved.TargetSnapshotHash=$snapshotHash;$wrongObserved.Rows=@($comparison.Rows[0].PSObject.Copy());$wrongObserved.Rows[0].ObservedTargetVersion='9.9.9';$receipt.Comparison=$wrongObserved;$receipt.TargetSnapshotHash=$snapshotHash;$receipt.ComparisonHash=(Get-WsmHashText ($wrongObserved|ConvertTo-Json -Depth 100 -Compress));Write-WsmJson $receiptPath $receipt;$receiptHash=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant();$observedBindingRejected=$false;try{Get-WsmAssistiveRestoreDecision $decisionPackage $decisionPackage.SHA256 $receiptPath $receiptHash $snapshotPath|Out-Null}catch{$observedBindingRejected=$true}
        Check $observedBindingRejected 'Comparison observed target version was not checked against the exact snapshot catalog.'
        $receipt.Comparison=$comparison;$receipt.ComparisonHash=(Get-WsmHashText ($comparison|ConvertTo-Json -Depth 100 -Compress));$targetSnapshot.Source.PSObject.Properties.Remove('Fingerprint');Write-WsmJson $snapshotPath $targetSnapshot;$snapshotHash=(Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash.ToLowerInvariant();$receipt.TargetSnapshotHash=$snapshotHash;$receipt.Comparison.TargetSnapshotHash=$snapshotHash;$receipt.ComparisonHash=(Get-WsmHashText ($receipt.Comparison|ConvertTo-Json -Depth 100 -Compress));Write-WsmJson $receiptPath $receipt;$receiptHash=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant();$fingerprintRejected=$false;try{Get-WsmAssistiveRestoreDecision $decisionPackage $decisionPackage.SHA256 $receiptPath $receiptHash $snapshotPath|Out-Null}catch{$fingerprintRejected=$true}
        Check $fingerprintRejected 'Restore accepted a target snapshot with no native target fingerprint.'
        $targetSnapshot.Source | Add-Member NoteProperty Fingerprint ('8'*64) -Force;Write-WsmJson $snapshotPath $targetSnapshot;$snapshotHash=(Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash.ToLowerInvariant();$receipt.TargetSnapshotHash=$snapshotHash;$receipt.Comparison.TargetSnapshotHash=$snapshotHash;$receipt.ComparisonHash=(Get-WsmHashText ($receipt.Comparison|ConvertTo-Json -Depth 100 -Compress));Write-WsmJson $receiptPath $receipt;$receiptHash=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant();$wrongFingerprintRejected=$false;try{Get-WsmAssistiveRestoreDecision $decisionPackage $decisionPackage.SHA256 $receiptPath $receiptHash $snapshotPath|Out-Null}catch{$wrongFingerprintRejected=$true}
        Check $wrongFingerprintRejected 'Restore accepted a native fingerprint that differs from the sealed package target.'

        function Test-WsmMigrationPackage($ManifestPath,$ExpectedHash,$CancellationToken){$script:previewPackage}
        function Assert-WsmMigrationHost($Identity,$Fingerprint){ }
        function Get-WsmAssistiveRestoreDecision($Package,$ExpectedHash,$ReceiptPath,$ReceiptHash,$SnapshotPath){$script:previewDecision}
        function Get-WsmOperationPaths($StateDirectory,$PairId){[pscustomobject]@{Root=$StateDirectory;State=$null;Journal=$null}}
        function Get-WsmOperationState($Paths,$Package){$script:previewState}
        function Get-WsmAssistiveNonCResultRows($Package,$TransferPlanPath,$TransferPlanHash,$ResultPath,$ResultHash,$StateDirectory){@{}}        $previewTarget=Join-Path $root 'preview-single\exact.ini';$previewMetadata=NewEntry '' 'preview single payload';$script:testEntries=@($previewMetadata);$previewItem=[pscustomobject]@{ItemId=$script:testItemId;Name='preview single';Decision='Include';Dependencies=@();MigrationSpec=[pscustomobject]@{Adapter='FileScope';TransferChannel='C';TargetPath=$previewTarget;Metadata='DaclOwner'}};$script:previewPackage=[pscustomobject]@{Root=$root;Plan=[pscustomobject]@{Items=@($previewItem)};Manifest=[pscustomobject]@{PairId='pair-fixture';PlanHash=('3'*64);Generation=9;Target=[pscustomobject]@{Fingerprint=$identity};ArtifactsHash=('b'*64)}};$script:previewDecision=[pscustomobject]@{SelectedItemIds=@($script:testItemId);Receipt=[pscustomobject]@{Decision='RestoreNow';AcceptedUnpreparedItemIds=@()};ReceiptHash=('4'*64);Snapshot=[pscustomobject]@{}};$script:previewState=[pscustomobject]@{Items=@()}
        $preview=Get-WsmAssistiveRestorePreview -ManifestPath 'fixture' -ExpectedHash ('2'*64) -StateDirectory $root -AssistiveDecisionReceiptPath 'fixture' -AssistiveDecisionReceiptHash ('4'*64) -AssistiveTargetSnapshotPath 'fixture'
        Check (($preview.Rows|Where-Object ItemId -EQ $script:testItemId).Action -ceq 'CreateSingleFile' -and ($preview.Rows|Where-Object ItemId -EQ $script:testItemId).Status -ceq 'Ready') 'Single-file preview did not classify the exact absent target path as ready.'
        $missingDrive=@('Q','R','S','T','U','V','W','X','Y','Z' | Where-Object {-not (Test-Path -LiteralPath ($_+':\'))} | Select-Object -First 1);Check ($missingDrive.Count -eq 1) 'No unused drive letter is available for the missing-volume preview case.';$missingTarget=$missingDrive[0]+':\Sites\gap.ini';$realTarget=$previewItem.MigrationSpec.TargetPath;$previewItem.MigrationSpec.TargetPath=$missingTarget;$gapPreview=Get-WsmAssistiveRestorePreview -ManifestPath 'fixture' -ExpectedHash ('2'*64) -StateDirectory $root -AssistiveDecisionReceiptPath 'fixture' -AssistiveDecisionReceiptHash ('4'*64) -AssistiveTargetSnapshotPath 'fixture';$previewItem.MigrationSpec.TargetPath=$realTarget
        $gapRow=$gapPreview.Rows|Where-Object ItemId -EQ $script:testItemId;Check ($gapRow.Status -ceq 'Deferred' -and $gapRow.Action -ceq 'PrepareSameLocation' -and $gapRow.Reason.Contains(('準備相同位置')) -and @($gapPreview.Problems).Count -eq 0 -and -not $gapPreview.Blocked -and -not (Test-Path -LiteralPath ($missingDrive[0]+':\'))) 'Missing target volume preview was not a non-problem Deferred PrepareSameLocation row without writes.'
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($previewTarget));[IO.File]::WriteAllText($previewTarget,'operator-owned');$script:previewState.Items=@();$script:rejectAssistiveTopologyPath=$previewTarget;$topologyPreview=Get-WsmAssistiveRestorePreview -ManifestPath 'fixture' -ExpectedHash ('2'*64) -StateDirectory $root -AssistiveDecisionReceiptPath 'fixture' -AssistiveDecisionReceiptHash ('4'*64) -AssistiveTargetSnapshotPath 'fixture';$script:rejectAssistiveTopologyPath=''
        Check (($topologyPreview.Rows|Where-Object ItemId -EQ $script:testItemId).Status -eq 'Blocked' -and [IO.File]::ReadAllText($previewTarget) -ceq 'operator-owned') 'Restore preview did not reject unsupported existing target topology without changing its bytes.'
        $preview=Get-WsmAssistiveRestorePreview -ManifestPath 'fixture' -ExpectedHash ('2'*64) -StateDirectory $root -AssistiveDecisionReceiptPath 'fixture' -AssistiveDecisionReceiptHash ('4'*64) -AssistiveTargetSnapshotPath 'fixture'
        Check (($preview.Rows|Where-Object ItemId -EQ $script:testItemId).Status -ceq 'BlockedConflict' -and [IO.File]::ReadAllText($previewTarget) -ceq 'operator-owned') 'Single-file preview did not block an external file at the exact target.'
        [IO.File]::Delete($previewTarget);$script:testEntries=@((NewEntry '' 'single-file payload'));$item.MigrationSpec.TargetPath=$singleTarget;$item.MigrationSpec | Add-Member NoteProperty TransferChannel C -Force;[IO.File]::WriteAllText($singleTarget,'single-file payload');$item | Add-Member NoteProperty Name 'single file' -Force;$state.Items=@($singleResult);$script:previewPackage.Plan.Items=@($item);$script:previewState=$state
        $preview=Get-WsmAssistiveRestorePreview -ManifestPath 'fixture' -ExpectedHash ('2'*64) -StateDirectory $root -AssistiveDecisionReceiptPath 'fixture' -AssistiveDecisionReceiptHash ('4'*64) -AssistiveTargetSnapshotPath 'fixture'
        Check (($preview.Rows|Where-Object ItemId -EQ $script:testItemId).Action -ceq 'VerifyOwnedSingleFile' -and ($preview.Rows|Where-Object ItemId -EQ $script:testItemId).Status -ceq 'Ready') 'Single-file preview did not accept only the exact owned file with matching bytes and metadata.'

        # R4: OfflineFullSet CV2 original-location contract at the two real consumers (preview producer of BlockedLocation, and the restore writer).
        $r4Saved=@{Items=$script:previewPackage.Plan.Items;Entries=$script:testEntries;Selected=$script:previewDecision.SelectedItemIds;Assistive=$script:previewPackage.Plan.PSObject.Properties['Assistive']}
        $r4GoodId='r4aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';$r4BadId='r4bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        $r4GoodPath=Join-Path $root 'r4-good\same.ini';$r4BadSource=Join-Path $root 'r4-src\moved.ini';$r4BadTarget=Join-Path $root 'r4-moved\moved.ini'
        function NewR4Item([string]$id,[string]$source,[string]$target){[pscustomobject]@{ItemId=$id;Name=('r4 '+$id);Decision='Include';Dependencies=@();MigrationSpec=[pscustomobject]@{Adapter='FileScope';TransferChannel='C';SourcePath=$source;TargetPath=$target;Metadata='DaclOwner'}}}
        function NewR4Entry([string]$id,[string]$content){$e=NewEntry '' $content;$e.ItemId=$id;$e}
        $r4GoodItem=NewR4Item $r4GoodId $r4GoodPath $r4GoodPath;$r4BadItem=NewR4Item $r4BadId $r4BadSource $r4BadTarget
        $r4Entries=@((NewR4Entry $r4GoodId 'r4 good payload'),(NewR4Entry $r4BadId 'r4 bad payload'))
        function Get-R4Preview([bool]$cv2){$script:previewPackage.Plan.Items=@($r4GoodItem,$r4BadItem);$script:testEntries=$r4Entries;$script:previewDecision.SelectedItemIds=@($r4GoodId,$r4BadId);$script:previewPackage.Plan|Add-Member NoteProperty Assistive ([pscustomobject]@{ContractVersion=$(if($cv2){2}else{1});SourcePolicy='ApprovedLocalVolumes'}) -Force;Get-WsmAssistiveRestorePreview -ManifestPath 'fixture' -ExpectedHash ('2'*64) -StateDirectory $root -AssistiveDecisionReceiptPath 'fixture' -AssistiveDecisionReceiptHash ('4'*64) -AssistiveTargetSnapshotPath 'fixture'}
        try{
            $r4Preview=Get-R4Preview $true
            $r4GoodRow=@($r4Preview.Rows|Where-Object ItemId -CEQ $r4GoodId)[0];$r4BadRow=@($r4Preview.Rows|Where-Object ItemId -CEQ $r4BadId)[0]
            Check ($r4BadRow.Action -ceq 'BlockedLocation' -and $r4BadRow.Status -ceq 'Blocked' -and $r4BadRow.Reason -like '*original location*') ('CV2 preview did not block a FileScope whose TargetPath differs from SourcePath: '+$r4BadRow.Action+'/'+$r4BadRow.Status+'/'+$r4BadRow.Reason)
            Check ($r4GoodRow.Action -ceq 'CreateSingleFile' -and $r4GoodRow.Status -ceq 'Ready') ('CV2 preview let a blocked-location sibling affect an original-location item: '+$r4GoodRow.Action+'/'+$r4GoodRow.Status)
            Check (@($r4Preview.Problems|Where-Object {$_.ItemId -ceq $r4BadId -and $_.Reason -like '*original location*'}).Count -eq 1 -and @($r4Preview.Problems|Where-Object ItemId -CEQ $r4GoodId).Count -eq 0) 'BlockedLocation was not reported as exactly one problem for the moved item only.'
            Check (-not [IO.Directory]::Exists((Split-Path $r4BadTarget -Parent)) -and -not [IO.Directory]::Exists((Split-Path $r4GoodPath -Parent))) 'Restore preview created target directories.'
            $r4Cv1Preview=Get-R4Preview $false
            $r4Cv1BadRow=@($r4Cv1Preview.Rows|Where-Object ItemId -CEQ $r4BadId)[0]
            Check ($r4Cv1BadRow.Action -cne 'BlockedLocation') 'Non-CV2 preview applied the OfflineFullSet original-location block.'
        }finally{$script:previewPackage.Plan.Items=$r4Saved.Items;$script:testEntries=$r4Saved.Entries;$script:previewDecision.SelectedItemIds=$r4Saved.Selected;$script:previewPackage.Plan.PSObject.Properties.Remove('Assistive')}
        # Writer side: the preview is fine for the original-location item; then the spec TargetPath is tampered before the write.
        $r4Package=[pscustomobject]@{Root=$root;SHA256=('a'*64);Plan=[pscustomobject]@{Assistive=[pscustomobject]@{ContractVersion=2;SourcePolicy='ApprovedLocalVolumes'}};Manifest=[pscustomobject]@{Generation=31;ArtifactsHash=('b'*64)}}
        $r4State=[pscustomobject]@{Items=@();PendingOperations=@()}
        $script:testEntries=@((NewR4Entry $r4GoodId 'r4 good payload'))
        $r4Control=Invoke-WsmAssistiveFileScopeRestore $r4GoodItem $r4Package $paths $r4State @{} $null
        Check ($r4Control.Status -ceq 'Succeeded' -and [IO.File]::ReadAllText($r4GoodPath) -ceq 'r4 good payload') 'CV2 writer rejected or failed an original-location FileScope.'
        $r4Tampered=NewR4Item $r4GoodId $r4GoodPath $r4BadTarget;$r4TamperMessage='';$r4TamperState=[pscustomobject]@{Items=@();PendingOperations=@()}
        try{Invoke-WsmAssistiveFileScopeRestore $r4Tampered $r4Package $paths $r4TamperState @{} $null|Out-Null}catch{$r4TamperMessage=$_.Exception.Message}
        Check ($r4TamperMessage -like '*original location*') ('CV2 writer did not reject a tampered TargetPath: '+$r4TamperMessage)
        Check (-not [IO.Directory]::Exists((Split-Path $r4BadTarget -Parent)) -and -not [IO.File]::Exists($r4BadTarget) -and @($r4TamperState.PendingOperations).Count -eq 0 -and @($r4TamperState.Items).Count -eq 0) 'CV2 writer touched the tampered target or recorded state before rejecting.'
        $r4Legacy=[pscustomobject]@{Root=$root;SHA256=('a'*64);Plan=[pscustomobject]@{Assistive=[pscustomobject]@{ContractVersion=1}};Manifest=[pscustomobject]@{Generation=32;ArtifactsHash=('b'*64)}}
        $r4LegacyOutcome=Invoke-WsmAssistiveFileScopeRestore $r4Tampered $r4Legacy $paths ([pscustomobject]@{Items=@();PendingOperations=@()}) @{} $null
        Check ($r4LegacyOutcome.Status -ceq 'Succeeded' -and [IO.File]::Exists($r4BadTarget)) 'Non-CV2 writer was subjected to the OfflineFullSet original-location rule.'
        $script:testEntries=$r4Saved.Entries

        # X-2: 容量依目標卷加總（同卷已選且會寫入的項目合計只比一次）；X-2b: 可寫入性預檢與掛載點。
        $capSaved=@{Items=$script:previewPackage.Plan.Items;Entries=$script:testEntries;Selected=$script:previewDecision.SelectedItemIds}
        $capRoot=Join-Path $root 'capacity-aggregate';[void][IO.Directory]::CreateDirectory($capRoot);$capKey=([IO.Path]::GetPathRoot($capRoot)).ToUpperInvariant()
        function NewCapItem([string]$id,[string]$target){[pscustomobject]@{ItemId=$id;Name=('cap '+$id);Decision='Include';Dependencies=@();MigrationSpec=[pscustomobject]@{Adapter='FileScope';TransferChannel='C';TargetPath=$target;Metadata='DaclOwner'}}}
        function NewCapEntry([string]$id,[long]$bytes){$capEntry=NewEntry '' ('cap payload '+$id);$capEntry.ItemId=$id;$capEntry.Data.Bytes=$bytes;$capEntry}
        function Get-CapPreview([object[]]$items,[object[]]$entries){$script:previewPackage.Plan.Items=@($items);$script:testEntries=@($entries);$script:previewDecision.SelectedItemIds=@($items|ForEach-Object ItemId);Get-WsmAssistiveRestorePreview -ManifestPath 'fixture' -ExpectedHash ('2'*64) -StateDirectory $root -AssistiveDecisionReceiptPath 'fixture' -AssistiveDecisionReceiptHash ('4'*64) -AssistiveTargetSnapshotPath 'fixture'}
        function CapRow($preview,[string]$id){@($preview.Rows|Where-Object ItemId -CEQ $id)[0]}
        $script:capFree=@{};$script:capProbes=0
        function Get-WsmAvailableBytes([string]$Path){$script:capProbes++;$key=([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))).ToUpperInvariant();if(-not $script:capFree.ContainsKey($key)){throw ('Unexpected capacity probe for '+$key)};[long]$script:capFree[$key]}
        $capA=NewCapItem 'cap-a' (Join-Path $capRoot 'a\one.ini');$capB=NewCapItem 'cap-b' (Join-Path $capRoot 'b\two.ini')
        $capEntries=@((NewCapEntry 'cap-a' 300MB),(NewCapEntry 'cap-b' 300MB))
        $script:capFree[$capKey]=700MB
        $capLow=Get-CapPreview @($capA,$capB) $capEntries
        Check ((CapRow $capLow 'cap-a').Action -ceq 'AddTargetCapacity' -and (CapRow $capLow 'cap-b').Action -ceq 'AddTargetCapacity' -and (CapRow $capLow 'cap-a').Status -ceq 'Deferred' -and (CapRow $capLow 'cap-b').Status -ceq 'Deferred') 'Two 300 MB items that fit separately in 700 MB but not together were not both AddTargetCapacity.'
        Check ((CapRow $capLow 'cap-a').Reason.Contains('同一磁碟上已選項目合計約 600 MiB') -and $script:capProbes -eq 1 -and @($capLow.Problems).Count -eq 0 -and -not $capLow.Blocked) 'Aggregate capacity gap did not explain the same-disk total, probe the volume once, or stayed a non-problem Deferred row.'
        $script:capFree[$capKey]=1GB
        $capHigh=Get-CapPreview @($capA,$capB) $capEntries
        Check ((CapRow $capHigh 'cap-a').Action -ceq 'CreateSingleFile' -and (CapRow $capHigh 'cap-b').Action -ceq 'CreateSingleFile' -and (CapRow $capHigh 'cap-a').Status -ceq 'Ready' -and (CapRow $capHigh 'cap-b').Status -ceq 'Ready') 'Two items with enough aggregate capacity were not both Ready.'
        # 大小寫不同的同一磁碟根仍屬同一卷。
        $capBLower=NewCapItem 'cap-b' ((Join-Path $capRoot 'b\two.ini').ToLowerInvariant());$script:capFree[$capKey]=700MB
        $capCase=Get-CapPreview @($capA,$capBLower) $capEntries
        Check ((CapRow $capCase 'cap-a').Action -ceq 'AddTargetCapacity' -and (CapRow $capCase 'cap-b').Action -ceq 'AddTargetCapacity') 'Volume keys were case sensitive: the same disk was counted as two volumes.'
        # 不同磁碟根分開計算（以 subst 建立第二個真實磁碟根）。
        $otherDrive=@('Q','R','S','T','U','V','W','X','Y','Z' | Where-Object {-not (Test-Path -LiteralPath ($_+':\'))} | Select-Object -First 1);Check ($otherDrive.Count -eq 1) 'No unused drive letter for the second-volume capacity case.'
        $otherRoot=Join-Path $root 'capacity-other-volume';[void][IO.Directory]::CreateDirectory($otherRoot);$otherSubst=$otherDrive[0]+':'
        & subst.exe $otherSubst $otherRoot | Out-Null
        try{
            Check ([IO.Directory]::Exists($otherSubst+'\')) 'subst did not create the second drive root fixture.'
            $capC=NewCapItem 'cap-c' ($otherSubst+'\c\three.ini');$script:capFree[$capKey]=700MB;$script:capFree[$otherSubst.ToUpperInvariant()+'\']=700MB
            $capEntries3=@($capEntries)+@((NewCapEntry 'cap-c' 300MB))
            $capSplit=Get-CapPreview @($capA,$capC) $capEntries3
            Check ((CapRow $capSplit 'cap-a').Action -ceq 'CreateSingleFile' -and (CapRow $capSplit 'cap-c').Action -ceq 'CreateSingleFile') 'Items on different volumes were summed together instead of per volume.'
            $script:capFree[$otherSubst.ToUpperInvariant()+'\']=100MB
            $capSplitLow=Get-CapPreview @($capA,$capC) $capEntries3
            Check ((CapRow $capSplitLow 'cap-a').Status -ceq 'Ready' -and (CapRow $capSplitLow 'cap-c').Action -ceq 'AddTargetCapacity') 'A short second volume did not defer only its own items.'
        }finally{& subst.exe $otherSubst /d | Out-Null}
        Check (-not [IO.Directory]::Exists($otherSubst+'\')) 'subst fixture drive was not removed.'
        # 已擁有、只需 readback 的項目不計入合計（此時 $item 為 VerifyOwnedSingleFile，宣稱 500 MB）。
        $ownedEntry=$capSaved.Entries[0];$ownedBytes=$ownedEntry.Data.Bytes;$ownedEntry.Data.Bytes=500MB;$script:capFree[$capKey]=700MB
        $capOwned=Get-CapPreview @($item,$capA) @($ownedEntry,$capEntries[0])
        $ownedEntry.Data.Bytes=$ownedBytes
        Check ((CapRow $capOwned $script:testItemId).Action -ceq 'VerifyOwnedSingleFile' -and (CapRow $capOwned 'cap-a').Action -ceq 'CreateSingleFile' -and (CapRow $capOwned 'cap-a').Status -ceq 'Ready') 'An already-owned readback-only item was counted in the volume total.'
        # 可寫入性預檢：一般目錄 Ready；拒絕目前使用者建立檔案的 ACL -> PermissionDenied；預覽前後目錄列舉相同。
        $roDir=Join-Path $root 'capacity-readonly';[void][IO.Directory]::CreateDirectory($roDir);$roItem=NewCapItem 'cap-ro' (Join-Path $roDir 'sub\x.ini');$roEntries=@((NewCapEntry 'cap-ro' 1MB));$script:capFree[$capKey]=1GB
        function Get-DirListing([string]$Path){@(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue|ForEach-Object FullName|Sort-Object)-join '|'}
        $listBeforeOk=Get-DirListing $roDir;$roMtimeBefore=[IO.Directory]::GetLastWriteTimeUtc($roDir).Ticks;$roOk=Get-CapPreview @($roItem) $roEntries
        Check ((CapRow $roOk 'cap-ro').Action -ceq 'CreateSingleFile' -and (CapRow $roOk 'cap-ro').Status -ceq 'Ready' -and (Get-DirListing $roDir) -ceq $listBeforeOk -and [IO.Directory]::GetLastWriteTimeUtc($roDir).Ticks -eq $roMtimeBefore) 'A writable ordinary directory was not Ready, or the preview left files behind or touched the directory timestamp.'
        $selfSid=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $denyRule=New-Object Security.AccessControl.FileSystemAccessRule($selfSid,[Security.AccessControl.FileSystemRights]'CreateFiles,CreateDirectories',[Security.AccessControl.InheritanceFlags]::None,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Deny)
        $roAcl=Get-Acl -LiteralPath $roDir;$roAcl.AddAccessRule($denyRule);Set-Acl -LiteralPath $roDir -AclObject $roAcl
        try{
            $denyControl=$false;try{[IO.File]::WriteAllText((Join-Path $roDir 'control.tmp'),'x')}catch{$denyControl=$true}
            Check $denyControl 'The deny ACL fixture did not actually block file creation.'
            $listBeforeDeny=Get-DirListing $roDir;$roDenied=Get-CapPreview @($roItem) $roEntries;$roRow=CapRow $roDenied 'cap-ro'
            Check ($roRow.Action -ceq 'PermissionDenied' -and $roRow.Status -ceq 'Deferred' -and $roRow.Reason.Contains('目前帳號無法寫入 '+$roDir) -and $roRow.Reason.Contains('請以具權限的帳號執行或調整權限後重新檢查') -and @($roDenied.Problems).Count -eq 0) 'A directory denying file creation was not a Deferred PermissionDenied row naming the directory.'
            Check ((Get-DirListing $roDir) -ceq $listBeforeDeny -and (Get-DirListing $roDir) -notlike '*wsm-writecheck*') 'The writability precheck left a file behind in the denied directory.'
        }finally{$roAcl=Get-Acl -LiteralPath $roDir;[void]$roAcl.RemoveAccessRule($denyRule);Set-Acl -LiteralPath $roDir -AclObject $roAcl}
        $roAfter=Get-CapPreview @($roItem) $roEntries
        Check ((CapRow $roAfter 'cap-ro').Status -ceq 'Ready' -and (Get-DirListing $roDir) -ceq $listBeforeOk) 'Removing the deny ACL did not restore a Ready, residue-free preview.'
        # 掛載點：產品不支援寫入掛載點底下（Assert-WsmNoReparse 本就拒絕任何 reparse 祖先），所以明確標 Blocked/MountPointNotSupported，不放寬防護。
        Check ($null -eq (Get-WsmAssistiveMountPointAncestor $capRoot)) 'An ordinary directory was reported as a volume mount point.'
        $mountFixture=Join-Path $root 'capacity-mount';$script:mountFixturePath=$mountFixture;[void][IO.Directory]::CreateDirectory((Join-Path $mountFixture 'data'))
        function Get-WsmAssistiveMountPointAncestor([string]$Path){if(([IO.Path]::GetFullPath($Path)).StartsWith($script:mountFixturePath,[StringComparison]::OrdinalIgnoreCase)){return $script:mountFixturePath};return $null}
        $mountItem=NewCapItem 'cap-mount' (Join-Path $mountFixture 'data\m.ini');$script:capProbes=0
        $mountPreview=Get-CapPreview @($mountItem) @((NewCapEntry 'cap-mount' 1MB));$mountRow=CapRow $mountPreview 'cap-mount'
        Check ($mountRow.Action -ceq 'MountPointNotSupported' -and $mountRow.Status -ceq 'Blocked' -and $mountRow.Reason.Contains('目標路徑位於另一個掛載點（'+$mountFixture+'）') -and $mountRow.Reason.Contains('工具不會寫入掛載點底下；請改用相同位置的一般目錄或另行處理。') -and $mountPreview.Blocked -and @($mountPreview.Problems|Where-Object ItemId -CEQ 'cap-mount').Count -eq 1 -and $script:capProbes -eq 0) 'A target under a volume mount point was not Blocked/MountPointNotSupported with the explicit reason and no capacity probe.'
        Remove-Item Function:\Get-WsmAssistiveMountPointAncestor
        # 非磁碟區掛載的 reparse（junction）仍走既有 Assert-WsmNoReparse 拒絕，不被放寬。
        $junction=Join-Path $root 'capacity-junction';$junctionTarget=Join-Path $root 'capacity-junction-target';[void][IO.Directory]::CreateDirectory($junctionTarget);[void](New-Item -ItemType Junction -Path $junction -Value $junctionTarget)
        try{
            Check ($null -eq (Get-WsmAssistiveMountPointAncestor $junction)) 'A plain junction was misreported as a volume mount point.'
            $junctionPreview=Get-CapPreview @((NewCapItem 'cap-junction' (Join-Path $junction 'j.ini'))) @((NewCapEntry 'cap-junction' 1MB))
            Check ((CapRow $junctionPreview 'cap-junction').Status -ceq 'Blocked' -and (CapRow $junctionPreview 'cap-junction').Action -ceq 'Blocked') 'Reparse protection was relaxed for a non-mount-point junction target.'
        }finally{[IO.Directory]::Delete($junction)}
        Check ([IO.Directory]::Exists($junctionTarget)) 'Junction cleanup removed the junction target.'
        Remove-Item Function:\Get-WsmAvailableBytes
        $script:previewPackage.Plan.Items=$capSaved.Items;$script:testEntries=$capSaved.Entries;$script:previewDecision.SelectedItemIds=$capSaved.Selected;Remove-Variable capFree,capProbes,mountFixturePath -Scope Script -ErrorAction SilentlyContinue

        # Final Assistive activation re-reads the exact durable receipt/snapshot
        # through the native decision seam and requires the whole sealed subset.
        $guardIdA=('a'*64);$guardIdB=('b'*64);$guardSourceId='sw-fixture';$guardIdentity=('9'*64);$guardManifestHash=('2'*64);$guardPlanHash=('3'*64)
        $guardSnapshot=[pscustomobject]@{CreatedUtc=[DateTime]::UtcNow.ToString('o');Source=[pscustomobject]@{Fingerprint=$guardIdentity};SoftwareCatalog=$softwareCatalog}
        $guardSnapshotPath=Join-Path $root 'cutover-target-snapshot.json';Write-WsmJson $guardSnapshotPath $guardSnapshot;$guardSnapshotHash=(Get-FileHash -LiteralPath $guardSnapshotPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $guardComparison=[pscustomobject][ordered]@{Revision=7;SourceSnapshotHash=('1'*64);TargetSnapshotHash=$guardSnapshotHash;SelectionRevision=3;Rows=@([pscustomobject][ordered]@{SoftwareId=$guardSourceId;SourceVersion='1.2.3';ChosenVersion='1.2.3';ObservedTargetVersion='1.2.3';TargetSoftwareId=$guardSourceId;Status='ChosenVersionObserved'})}
        $guardPlan=[pscustomobject]@{Kind='MigrationPlan';SchemaVersion=3;PairId='pair-fixture';Assistive=[pscustomobject]@{SourceSnapshotHash=('1'*64);ApprovedItemIds=@($guardIdA,$guardIdB)};Items=@([pscustomobject]@{ItemId=$guardIdA;Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='ManualWorkflow'}},[pscustomobject]@{ItemId=$guardIdB;Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='ManualWorkflow'}})}
        $guardPackage=[pscustomobject]@{SHA256=$guardManifestHash;PlanHash=$guardPlanHash;Plan=$guardPlan;Manifest=[pscustomobject]@{PairId='pair-fixture';PlanHash=$guardPlanHash;Generation=9;Final=$true;Target=[pscustomobject]@{Fingerprint=$guardIdentity}}}
        $guardReceipt=[pscustomobject][ordered]@{SchemaVersion=1;Kind='AssistiveTargetDecisionReceipt';ReceiptId='fixture';PairId='pair-fixture';PlanHash=$guardPlanHash;ManifestHash=$guardManifestHash;Generation=9;TargetSnapshotHash=$guardSnapshotHash;ComparisonRevision=7;SelectionRevision=3;Decision='RestoreNow';Owner='Fixture owner';Reason='Exercise full approved set cutover guard';SelectedItemIds=@($guardIdA,$guardIdB);AcceptedUnpreparedItemIds=@();CreatedUtc=[DateTime]::UtcNow.ToString('o');Comparison=$guardComparison;ComparisonHash=(Get-WsmHashText ($guardComparison|ConvertTo-Json -Depth 100 -Compress));SHA256=('4'*64)}
        $guardBody=[ordered]@{};foreach($property in $guardReceipt.PSObject.Properties){if($property.Name -cne 'SHA256'){$guardBody[$property.Name]=$property.Value}};$guardReceipt.SHA256=Get-WsmHashText ($guardBody|ConvertTo-Json -Depth 20 -Compress)
        $guardReceiptPath=Join-Path $root 'cutover-decision-receipt.json';Write-WsmJson $guardReceiptPath $guardReceipt;$guardReceiptHash=(Get-FileHash -LiteralPath $guardReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:currentSoftwareFixture=$softwareCatalog
        function Get-WsmAssistiveRestoreDecision($Package,[string]$ManifestHash,[string]$ReceiptPath,[string]$ReceiptHash,[string]$SnapshotPath){& $script:nativeAssistiveRestoreDecision $Package $ManifestHash $ReceiptPath $ReceiptHash $SnapshotPath}
        $guardAttempt=[pscustomobject]@{ManifestHash=$guardManifestHash;Generation=9;DecisionReceiptPath=$guardReceiptPath;DecisionReceiptHash=$guardReceiptHash;TargetSnapshotPath=$guardSnapshotPath;TargetSnapshotHash=$guardSnapshotHash;SelectedItemIds=@($guardIdA,$guardIdB)}
        $script:previewState=[pscustomobject]@{ManifestHash=$guardManifestHash;Generation=9;PendingOperations=@();Items=@();RestoreAttempt=$guardAttempt}
        Assert-WsmAssistiveCutoverActivationIntent $guardPackage $root
        Check $true 'A fresh receipt selecting the complete sealed approved set did not pass cutover intent validation.'
        $guardReceipt.SelectedItemIds=@($guardIdA);$guardBody=[ordered]@{};foreach($property in $guardReceipt.PSObject.Properties){if($property.Name -cne 'SHA256'){$guardBody[$property.Name]=$property.Value}};$guardReceipt.SHA256=Get-WsmHashText ($guardBody|ConvertTo-Json -Depth 20 -Compress);Write-WsmJson $guardReceiptPath $guardReceipt;$guardReceiptHash=(Get-FileHash -LiteralPath $guardReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant();$guardAttempt.DecisionReceiptHash=$guardReceiptHash;$guardAttempt.SelectedItemIds=@($guardIdA)
        $subsetRejected=$false;try{Assert-WsmAssistiveCutoverActivationIntent $guardPackage $root|Out-Null}catch{$subsetRejected=$true}
        Check $subsetRejected 'Cutover activation accepted an updated receipt that deselected a previously staged sealed item.'
        $guardAttempt.DecisionReceiptPath='';$missingReceiptPathRejected=$false;try{Assert-WsmAssistiveCutoverActivationIntent $guardPackage $root|Out-Null}catch{$missingReceiptPathRejected=$true}
        Check $missingReceiptPathRejected 'Schema 3 cutover bypassed current receipt/snapshot validation when durable receipt references were missing.'
        $guardAttempt.DecisionReceiptPath=$guardReceiptPath;$guardAttempt.DecisionReceiptHash=('f'*64);$staleReceiptRejected=$false;try{Assert-WsmAssistiveCutoverActivationIntent $guardPackage $root|Out-Null}catch{$staleReceiptRejected=$true}
        Check $staleReceiptRejected 'Schema 3 cutover accepted a stale durable decision receipt hash.'
        $script:previewState=[pscustomobject]@{Items=@()}

        $repairRoot=Join-Path $root 'repair';[void][IO.Directory]::CreateDirectory($repairRoot);$repairTarget=Join-Path $repairRoot 'worker.bin';$repairStaging=$repairTarget+'.wsm-'+[Guid]::NewGuid().ToString('N')+'.tmp';$repairBackup=$repairTarget+'.wsm-assistive-backup-'+$script:testItemId.Substring(0,12)+'-'+[Guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText($repairBackup,'prior bytes');[IO.File]::WriteAllText($repairStaging,'approved bytes');$newHash=(Get-FileHash -LiteralPath $repairStaging -Algorithm SHA256).Hash.ToLowerInvariant();$oldHash=(Get-FileHash -LiteralPath $repairBackup -Algorithm SHA256).Hash.ToLowerInvariant()
        $repairItem=[pscustomobject]@{ItemId=$script:testItemId;Name='preview single';Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='FileScope';TargetPath=$repairRoot}}
        $repairMetadata=[pscustomobject]@{MetadataMode='DaclOwner';Sddl='';Attributes=0;CreationUtc=$script:fixtureUtc;LastWriteUtc=$script:fixtureUtc};$repairOp=[pscustomobject]@{ItemId=$script:testItemId;Phase='AssistiveFileReplace';ManifestHash=('d'*64);Generation=2;RelativePath='worker.bin';Target=$repairTarget;Staging=$repairStaging;Backup=$repairBackup;PreviousHash=$oldHash;ExpectedHash=$newHash;ExpectedMetadata=$repairMetadata;WasOwned=$true;PriorOwner=[pscustomobject]@{MetadataHash=(Get-WsmAssistiveMetadataHash $repairMetadata)}}
        $repairPackage=[pscustomobject]@{SHA256=('d'*64);Manifest=[pscustomobject]@{Generation=2}}
        $repairPaths=[pscustomobject]@{Root=$root;State=$null;Journal=$null};$repairState=[pscustomobject]@{Items=@();PendingOperations=@($repairOp)}
        Complete-WsmAssistiveOperationRepair $repairItem $repairOp $repairPackage $repairPaths $repairState | Out-Null
        Check ([IO.File]::ReadAllText($repairTarget) -ceq 'approved bytes' -and [IO.File]::ReadAllText($repairBackup) -ceq 'prior bytes') 'Assistive journal repair did not finish an exact interrupted prior-file replacement.'
        Check (@($repairState.PendingOperations).Count -eq 0 -and $repairState.Items[0].Status -eq 'Partial' -and $repairState.Items[0].AppliedManifestHash -eq '') 'Per-file repair incorrectly marked a partial scope fully applied or left intent ambiguous.'
        $singleRepairRoot=Join-Path $root 'single-repair';[void][IO.Directory]::CreateDirectory($singleRepairRoot);$singleRepairTarget=Join-Path $singleRepairRoot 'exact.ini';$singleRepairStaging=$singleRepairTarget+'.wsm-'+[Guid]::NewGuid().ToString('N')+'.tmp';$singleRepairBackup=$singleRepairTarget+'.wsm-assistive-backup-'+$script:testItemId.Substring(0,12)+'-'+[Guid]::NewGuid().ToString('N');[IO.File]::WriteAllText($singleRepairBackup,'prior single bytes');[IO.File]::WriteAllText($singleRepairStaging,'approved single bytes');$singleRepairHash=(Get-FileHash -LiteralPath $singleRepairStaging -Algorithm SHA256).Hash.ToLowerInvariant();$singleOldHash=(Get-FileHash -LiteralPath $singleRepairBackup -Algorithm SHA256).Hash.ToLowerInvariant();$singleMetadata=[pscustomobject]@{MetadataMode='DaclOwner';Sddl='';Attributes=0;CreationUtc=$script:fixtureUtc;LastWriteUtc=$script:fixtureUtc};$singleRepairOp=[pscustomobject]@{ItemId=$script:testItemId;Phase='AssistiveFileReplace';ManifestHash=('d'*64);Generation=3;RelativePath='';Target=$singleRepairTarget;Staging=$singleRepairStaging;Backup=$singleRepairBackup;PreviousHash=$singleOldHash;ExpectedHash=$singleRepairHash;ExpectedMetadata=$singleMetadata;WasOwned=$true;PriorOwner=[pscustomobject]@{MetadataHash=(Get-WsmAssistiveMetadataHash $singleMetadata)}};$singleRepairItem=[pscustomobject]@{ItemId=$script:testItemId;Name='preview single';Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='FileScope';TargetPath=$singleRepairTarget}};$singleRepairState=[pscustomobject]@{Items=@();PendingOperations=@($singleRepairOp)};Complete-WsmAssistiveOperationRepair $singleRepairItem $singleRepairOp $repairPackage $repairPaths $singleRepairState | Out-Null
        Check ([IO.File]::ReadAllText($singleRepairTarget) -ceq 'approved single bytes' -and [IO.File]::ReadAllText($singleRepairBackup) -ceq 'prior single bytes' -and $singleRepairState.Items[0].OwnedFiles[0].RelativePath -ceq '' -and $singleRepairState.Items[0].OwnedFiles[0].TargetPath -ceq $singleRepairTarget) 'Single-file recovery did not reconcile the exact empty-relative file target and rollback copy.'
        # Strict task and IIS adapter contracts intentionally omit Desired.Name.
        # Exercise the shared projection and durable Assistive repair consumer
        # with only the native state/readback boundary replaced.
        $identityCases=@(
            [pscustomobject]@{Adapter='ScheduledTask';Desired=[pscustomobject]@{TaskPath='\Ops\';TaskName='Rotate';FolderSecurity=@([pscustomobject]@{Path='\';SecuritySddl='O:SYG:SYD:(A;;FA;;;SY)';ExistingPolicy='VerifyExact'})};Expected='\Ops\Rotate'},
            [pscustomobject]@{Adapter='IISSection';Desired=[pscustomobject]@{SectionPath='system.webServer/security';LocationPath='';Xml='<security />';Changes=@()};Expected='system.webServer/security'},
            [pscustomobject]@{Adapter='IISLocation';Desired=[pscustomobject]@{SectionPath='system.webServer/security';LocationPath='Default Web Site/api';Xml='<security />';Changes=@()};Expected='system.webServer/security @ Default Web Site/api'}
        )
        $script:nativeAssistiveAdapterState=(Get-Command Get-WsmAdapterState -CommandType Function).ScriptBlock
        $script:nativeAssistiveAdapterConfiguration=(Get-Command Test-WsmAdapterConfiguration -CommandType Function).ScriptBlock
        foreach($identityCase in $identityCases){
            $identitySpec=[pscustomobject]@{Adapter=$identityCase.Adapter;Desired=$identityCase.Desired}
            Check (-not $identitySpec.Desired.PSObject.Properties['Name'] -and (Get-WsmAdapterObjectIdentity $identitySpec) -ceq $identityCase.Expected) ($identityCase.Adapter+' target identity was not projected from its strict native target fields.')
            $identityItem=[pscustomobject]@{ItemId=$script:testItemId;MigrationSpec=$identitySpec}
            $identityOperation=[pscustomobject]@{ItemId=$script:testItemId;Phase='AssistiveAdapterCreating';Adapter=$identityCase.Adapter;ManifestHash=('d'*64);Generation=12;Before=[pscustomobject]@{Exists=$false};AbsentBefore=$true;DesiredHash=(Get-WsmHashText ($identitySpec.Desired|ConvertTo-Json -Depth 40 -Compress));FolderCreateIntents=@();AuxiliaryOwnership=@()}
            $identityPackage=[pscustomobject]@{SHA256=('d'*64);Manifest=[pscustomobject]@{Generation=12}}
            $identityState=[pscustomobject]@{Items=@();PendingOperations=@($identityOperation);Stage='Running'}
            if($identityCase.Adapter -ceq 'ScheduledTask'){
                Set-Item Function:\script:Get-WsmAdapterState -Value {param($Spec)[pscustomobject]@{Exists=$true;Configuration=$Spec.Desired}}
                Set-Item Function:\script:Test-WsmAdapterConfiguration -Value {param($Spec,$Phase,[object[]]$OwnedReceipts=@())[pscustomobject]@{Passed=$true;Actual=$Spec.Desired;Problems=@()}}
                Complete-WsmAssistiveOperationRepair $identityItem $identityOperation $identityPackage $repairPaths $identityState | Out-Null
                Check ($identityState.Items[0].Target -ceq $identityCase.Expected -and @($identityState.PendingOperations).Count -eq 0) 'ScheduledTask durable repair did not persist its strict-contract native target identity.'
            }
        }
        Set-Item Function:\script:Get-WsmAdapterState -Value $script:nativeAssistiveAdapterState
        Set-Item Function:\script:Test-WsmAdapterConfiguration -Value $script:nativeAssistiveAdapterConfiguration

        # Run the actual schema-3 Assistive restore consumer for strict IIS
        # Desired shapes. Only native IIS read/write and package-state edges
        # are isolated; Invoke-WsmAdapterRestore and the restore loop stay real.
        $script:nativeAssistiveDecisionForLoop=(Get-Command Get-WsmAssistiveRestoreDecision -CommandType Function).ScriptBlock
        $script:nativeAssistiveTestPackageForLoop=(Get-Command Test-WsmMigrationPackage -CommandType Function).ScriptBlock
        $script:nativeAssistiveAssertHostForLoop=(Get-Command Assert-WsmMigrationHost -CommandType Function).ScriptBlock
        $script:nativeAssistiveMachineIdentityForLoop=(Get-Command Get-WsmMachineIdentity -CommandType Function).ScriptBlock
        $script:nativeAssistiveNonCRowsForLoop=(Get-Command Get-WsmAssistiveNonCResultRows -CommandType Function).ScriptBlock
        $script:nativeAssistiveAssertFreshForLoop=(Get-Command Assert-WsmAssistiveReceiptFresh -CommandType Function).ScriptBlock
        $script:nativeAssistiveRegisterJobForLoop=(Get-Command Register-WsmAssistivePackageMaterials -CommandType Function).ScriptBlock
        $script:nativeAssistiveGetPathsForLoop=(Get-Command Get-WsmOperationPaths -CommandType Function).ScriptBlock
        $script:nativeAssistiveGetStateForLoop=(Get-Command Get-WsmOperationState -CommandType Function).ScriptBlock
        $script:nativeAssistiveReservationsForLoop=(Get-Command Get-WsmAssistiveReservations -CommandType Function).ScriptBlock
        $script:nativeAssistiveCheckpointForLoop=(Get-Command Confirm-WsmOutputStateCheckpoint -CommandType Function).ScriptBlock
        $script:nativeAssistiveIisWriteForLoop=(Get-Command Invoke-WsmIisConfigRestore -CommandType Function).ScriptBlock
        $script:nativeAssistiveNewIisManagerForLoop=(Get-Command New-WsmIisManager -CommandType Function).ScriptBlock
        $script:nativeAssistiveGetOperationPaths=(Get-Command Get-WsmOperationPaths -CommandType Function).ScriptBlock
        $script:nativeAssistiveInstallerSnapshot=(Get-Command Get-WsmInstallerSnapshot -CommandType Function).ScriptBlock
        $script:nativeAssistiveBootStamp=(Get-Command Get-WsmBootStamp -CommandType Function).ScriptBlock
        $script:nativeAssistiveSettingSnapshot=(Get-Command Get-WsmSettingNativeSnapshot -CommandType Function).ScriptBlock
        $script:nativeAssistiveSetSetting=(Get-Command Set-WsmSettingNativeState -CommandType Function).ScriptBlock
        $script:nativeAssistiveInstallerConsumers=(Get-Command Test-WsmInstallerConsumers -CommandType Function).ScriptBlock
        $script:nativeAssistiveInstallerPolicy=(Get-Command Assert-WsmInstallerPolicy -CommandType Function).ScriptBlock
        $script:assistiveLoopPresent=$false;$script:assistiveLoopState=$null;$script:assistiveLoopPaths=[pscustomobject]@{Root=$root;State=(Join-Path $root 'loop-state.json');Journal=(Join-Path $root 'loop-journal.jsonl')}
        $script:assistiveLoopPackage=$null
        Set-Item Function:\Test-WsmMigrationPackage -Value {param([string]$ManifestPath,[string]$ExpectedHash,$CancellationToken)$script:assistiveLoopPackage}
        Set-Item Function:\Assert-WsmMigrationHost -Value {param($Identity,[string]$ExpectedFingerprint)}
        Set-Item Function:\Get-WsmMachineIdentity -Value {[pscustomobject]@{Fingerprint=('c'*64)}}
        Set-Item Function:\Get-WsmAssistiveNonCResultRows -Value {param($Package,[string]$TransferPlanPath,[string]$TransferPlanHash,[string]$ResultPath,[string]$ResultHash,[string]$StateDirectory)@{}}
        Set-Item Function:\Get-WsmAssistiveRestoreDecision -Value {param($Package,[string]$ManifestHash,[string]$ReceiptPath,[string]$ReceiptHash,[string]$SnapshotPath)[pscustomobject]@{Decision='RestoreNow';ReceiptPath='fixture-receipt';ReceiptHash=('4'*64);SnapshotPath='fixture-snapshot';SelectedItemIds=@($Package.Plan.Items.ItemId);Snapshot=[pscustomobject]@{};Receipt=[pscustomobject]@{Decision='RestoreNow';TargetSnapshotHash=('5'*64)}}}
        Set-Item Function:\Assert-WsmAssistiveReceiptFresh -Value {param($Package,$Decision)$true}
        Set-Item Function:\Register-WsmAssistivePackageMaterials -Value {param($Package,$Decision,[string]$Workspace,$Preview)[pscustomobject]@{MaterialIds=@();OperationId=''}}
        Set-Item Function:\Get-WsmOperationPaths -Value {param([string]$StateDirectory,[string]$PairId)$script:assistiveLoopPaths}
        Set-Item Function:\Get-WsmOperationState -Value {param($Paths,$Package)$script:assistiveLoopState}
        Set-Item Function:\Get-WsmAssistiveReservations -Value {param($Item,$Package,[string]$Workspace)@()}
        Set-Item Function:\Confirm-WsmOutputStateCheckpoint -Value {param([string]$StateDirectory,[string]$PairId,[string]$PlanHash)}
        $script:iisLoopSectionInfo=[pscustomobject]@{}
        $script:iisLoopSectionInfo | Add-Member ScriptMethod GetRawXml {return [string]$script:iisLoopXml}
        $script:iisLoopSectionInfo | Add-Member ScriptMethod SetRawXml {param([string]$Xml)$script:iisLoopXml=$Xml}
        $script:iisLoopSection=[pscustomobject]@{SectionInformation=$script:iisLoopSectionInfo}
        $script:iisLoopConfiguration=[pscustomobject]@{}
        $script:iisLoopConfiguration | Add-Member ScriptMethod GetSection {param([string]$SectionPath,[string]$LocationPath)$script:iisLoopSection}
        $script:iisLoopManager=[pscustomobject]@{}
        $script:iisLoopManager | Add-Member ScriptMethod GetApplicationHostConfiguration {$script:iisLoopConfiguration}
        $script:iisLoopManager | Add-Member ScriptMethod CommitChanges {}
        $script:iisLoopManager | Add-Member ScriptMethod Dispose {}
        Set-Item Function:\New-WsmIisManager -Value {$script:iisLoopManager}
        foreach($adapterName in @('IISSection','IISLocation')){
            $location='';if($adapterName -ceq 'IISLocation'){$location='Default Web Site/api'}
            $script:iisLoopXml='<security><access enabled="true" policy="read" /></security>'
            $desiredIis=[pscustomobject]@{SectionPath='system.webServer/security';LocationPath=$location;Xml='<security><access enabled="false" policy="read,write" /></security>';Changes=@([pscustomobject]@{FieldPointer='/security/access/@policy';Operation='SetAttribute';ElementName='access';KeyAttributes=@();AttributeName='policy';BeforeValue='read';AfterValue='read,write'},[pscustomobject]@{FieldPointer='/security/access/@enabled';Operation='SetAttribute';ElementName='access';KeyAttributes=@();AttributeName='enabled';BeforeValue='true';AfterValue='false'})}
            $loopSpec=[pscustomobject]@{Adapter=$adapterName;Desired=$desiredIis;SourceXml='<security><access enabled="true" policy="read" /></security>';SourceAutoStart='true';DesiredFinalState='Enabled';StagedDisabled=$true;ActivationPolicyFieldPointer='/security/access/@enabled';ReviewedActivation=[pscustomobject]@{FinalState='Enabled';Owner='Fixture owner';Reason='Preserve the explicitly approved source startup behavior.';SourceAutoStart='true';FieldPointer='/security/access/@enabled';StagedValue='false';FinalValue='true'}}
            $loopItem=[pscustomobject]@{ItemId=$script:testItemId;Name=$adapterName;Decision='Include';MigrationSpec=$loopSpec}
            $loopPackage=[pscustomobject]@{Root=$root;SHA256=('a'*64);PlanHash=('b'*64);Plan=[pscustomobject]@{SchemaVersion=3;Items=@($loopItem)};Manifest=[pscustomobject]@{PairId='pair-assistive-loop';PlanHash=('b'*64);Generation=13;Final=$true;Target=[pscustomobject]@{Fingerprint=('c'*64)}}}
            $script:assistiveLoopPackage=$loopPackage
            $script:assistiveLoopPresent=$false;$script:assistiveLoopState=[pscustomobject]@{Items=@();PendingOperations=@();Cutover=$null;ManifestHash='';Generation=0;Stage='NotStarted';AssistiveFileResults=@();JournalHash=('0'*64)}
            $loopPreview=Get-WsmAssistiveRestorePreview -ManifestPath 'fixture' -ExpectedHash ('a'*64) -StateDirectory $root -AssistiveDecisionReceiptPath 'fixture-receipt' -AssistiveDecisionReceiptHash ('4'*64) -AssistiveTargetSnapshotPath 'fixture-snapshot'
            Check (($loopPreview.Rows[0].Status -ceq 'Ready') -and ($loopPreview.Rows[0].Action -ceq 'ApplyReviewedIisChanges')) ($adapterName+' native preview did not validate its exact before-state field changes.')
            Check (-not $loopPreview.Rows[0].PSObject.Properties['CredentialRequired'] -and -not $loopPreview.Rows[0].PSObject.Properties['CredentialKind']) ($adapterName+' preview marked a row that needs no credential.')
            if($adapterName -ceq 'IISSection'){$poolSpec=[pscustomobject]@{Adapter='IISPool';SecretRef='PoolPreviewSecret';Desired=[pscustomobject]@{Name='PreviewPool';Xml='<add name="PreviewPool"><processModel identityType="SpecificUser" userName="CONTOSO\poolsvc" /></add>'}};$poolItem=[pscustomobject]@{ItemId=$script:testItemId;Name='Preview pool';Decision='Include';MigrationSpec=$poolSpec};$poolPackage=[pscustomobject]@{Root=$root;SHA256=('a'*64);PlanHash=('b'*64);Plan=[pscustomobject]@{SchemaVersion=3;Items=@($poolItem)};Manifest=$loopPackage.Manifest};$script:assistiveLoopPackage=$poolPackage;try{$poolPreview=Get-WsmAssistiveRestorePreview -ManifestPath 'fixture' -ExpectedHash ('a'*64) -StateDirectory $root -AssistiveDecisionReceiptPath 'fixture-receipt' -AssistiveDecisionReceiptHash ('4'*64) -AssistiveTargetSnapshotPath 'fixture-snapshot'}finally{$script:assistiveLoopPackage=$loopPackage};Check ($poolPreview.Rows[0].CredentialRequired -eq $true -and $poolPreview.Rows[0].CredentialKind -ceq 'IISPool') 'Preview did not mark an IIS pool row that needs a credential.'}
            $loopCreated=Invoke-WsmAssistiveRestore $loopPackage ('a'*64) $root @{} @{} $null @() 'fixture-receipt' ('4'*64) 'fixture-snapshot' $loopPreview
            Check ($loopCreated.Results[0].Status -ceq 'Succeeded' -and $loopCreated.Results[0].Target -ceq (Get-WsmAdapterObjectIdentity $loopItem.MigrationSpec) -and $script:iisLoopXml -ceq $desiredIis.Xml) ($adapterName+' real Assistive restore loop failed to apply exact typed IIS field changes and identify the target. status='+$loopCreated.Results[0].Status+' error='+$loopCreated.Results[0].Error+' actual='+$script:iisLoopXml+' preview='+$loopPreview.Rows[0].Status+'/'+$loopPreview.Rows[0].Reason)
            $loopPackage.Manifest.Generation=14;$script:assistiveLoopState.Items=@($loopCreated.Items);$loopPreview=Get-WsmAssistiveRestorePreview -ManifestPath 'fixture' -ExpectedHash ('a'*64) -StateDirectory $root -AssistiveDecisionReceiptPath 'fixture-receipt' -AssistiveDecisionReceiptHash ('4'*64) -AssistiveTargetSnapshotPath 'fixture-snapshot'
            Check (($loopPreview.Rows[0].Status -ceq 'Ready') -and ($loopPreview.Rows[0].Action -ceq 'VerifyOwnedIisConfig')) ($adapterName+' native preview did not accept exact already-owned staged XML.')
            $loopRetry=Invoke-WsmAssistiveRestore $loopPackage ('a'*64) $root @{} @{} $null @() 'fixture-receipt' ('4'*64) 'fixture-snapshot' $loopPreview
            Check ($loopRetry.Results[0].Status -ceq 'Succeeded' -and $loopRetry.Results[0].Target -ceq $loopCreated.Results[0].Target -and $loopRetry.Results[0].PriorManifestHash -ceq ('a'*64)) ($adapterName+' verified-owned retry did not preserve the exact target identity and prior-generation ownership.')
            $loopRecord=$loopCreated.Items[0];$repairBefore=$loopRecord.Before;$iisRepairOp=[pscustomobject]@{ItemId=$script:testItemId;Phase='AssistiveAdapterCreating';Adapter=$adapterName;ManifestHash=('a'*64);Generation=13;Before=$repairBefore;BeforeHash=(Get-WsmHashText ($repairBefore|ConvertTo-Json -Depth 30 -Compress));DesiredHash=(Get-WsmHashText ($desiredIis|ConvertTo-Json -Depth 40 -Compress));AbsentBefore=$false;UpdatedByTool=$true;FolderCreateIntents=@();AuxiliaryOwnership=@()}
            $iisRepairState=[pscustomobject]@{Items=@();PendingOperations=@($iisRepairOp);Stage='Running'}
            Complete-WsmAssistiveOperationRepair $loopItem $iisRepairOp $loopPackage $script:assistiveLoopPaths $iisRepairState | Out-Null
            Check ($iisRepairState.Items[0].UpdatedByTool -and -not $iisRepairState.Items[0].CreatedByTool -and $iisRepairState.Items[0].BeforeHash -eq $iisRepairOp.BeforeHash -and $iisRepairState.Items[0].Target -ceq (Get-WsmAdapterObjectIdentity $loopItem.MigrationSpec)) ($adapterName+' interrupted reviewed IIS update did not recover exact XML ownership evidence.')
            Check (Test-WsmRollbackRecordOwnership $iisRepairState.Items[0] $loopSpec) ($adapterName+' reviewed update record did not pass durable ownership verification.')
            $script:iisLoopXml=Get-WsmIisReviewedActivationXml $loopSpec
            Check ((Test-WsmAdapterConfiguration $loopSpec Final).Passed -and (Test-WsmRollbackRecordOwnership $iisRepairState.Items[0] $loopSpec)) ($adapterName+' legitimate reviewed final XML was rejected by native verification or durable rollback ownership.')
            $script:iisLoopXml='<security><access enabled="true" policy="drift" /></security>'
            Check (-not (Test-WsmAdapterConfiguration $loopSpec Staged).Passed -and -not (Test-WsmAdapterConfiguration $loopSpec Final).Passed) ($adapterName+' native verification accepted drifted IIS XML.')
            Check (Test-WsmRollbackRecordOwnership $iisRepairState.Items[0] $loopSpec) ($adapterName+' durable ownership was incorrectly coupled to live XML instead of caller-side staged/final verification.')
            $badPrior=$iisRepairState.Items[0] | ConvertTo-Json -Depth 30 | ConvertFrom-Json;$badPrior.PriorXml='<security />'
            Check (-not (Test-WsmRollbackRecordOwnership $badPrior $loopSpec)) ($adapterName+' rollback ownership accepted PriorXml that differed from durable Before.Xml.')
            $script:iisLoopXml=Get-WsmIisReviewedActivationXml $loopSpec
            $rollbackOperation=[pscustomobject]@{ItemId=$script:testItemId;Phase='RollbackAdapter';ManifestHash=('a'*64);Adapter=$adapterName;SpecHash=(Get-WsmHashText ($loopSpec | ConvertTo-Json -Depth 40 -Compress))}
            Complete-WsmAdapterRollback $loopItem $rollbackOperation $script:assistiveLoopPaths $iisRepairState
            Check ($iisRepairState.Items[0].Status -ceq 'RolledBack' -and -not $iisRepairState.Items[0].UpdatedByTool -and $script:iisLoopXml -ceq [string]$loopCreated.Items[0].Before.Xml) ($adapterName+' final-to-staged-to-exact-prior rollback did not complete through native XML readback.')
        }
        $script:iisLoopXml=[string]$loopCreated.Items[0].Before.Xml;$loopPackage.Manifest.Generation=15;$script:assistiveLoopPackage=$loopPackage;$script:assistiveLoopState=[pscustomobject]@{Items=@();PendingOperations=@();Cutover=$null;ManifestHash='';Generation=0;Stage='NotStarted';AssistiveFileResults=@();JournalHash=('0'*64)}
        Set-Item Function:\Invoke-WsmIisConfigRestore -Value {param($Spec)$nativeResult=& $script:nativeAssistiveIisWriteForLoop $Spec;$nativeResult.PriorXml='<operator-mismatched-prior />';$nativeResult}
        $priorMismatchPreview=Get-WsmAssistiveRestorePreview -ManifestPath 'fixture' -ExpectedHash ('a'*64) -StateDirectory $root -AssistiveDecisionReceiptPath 'fixture-receipt' -AssistiveDecisionReceiptHash ('4'*64) -AssistiveTargetSnapshotPath 'fixture-snapshot'
        $priorMismatchResult=Invoke-WsmAssistiveRestore $loopPackage ('a'*64) $root @{} @{} $null @() 'fixture-receipt' ('4'*64) 'fixture-snapshot' $priorMismatchPreview
        Check ($priorMismatchResult.Results[0].Status -ceq 'Failed' -and @($script:assistiveLoopState.PendingOperations | Where-Object Phase -ceq 'AssistiveAdapterCreating').Count -eq 1 -and $script:iisLoopXml -ceq $desiredIis.Xml) 'Assistive IIS accepted a native PriorXml race or discarded its durable ambiguous-write intent.'
        Set-Item Function:\Invoke-WsmIisConfigRestore -Value $script:nativeAssistiveIisWriteForLoop

        # Exercise WindowsFeature through the Assistive consumer and real
        # installer safety coordinator, substituting only native OS APIs.
        $script:featureInstalled=$false;$script:featureInstallCalls=0;$script:featureTrace=New-Object 'System.Collections.Generic.List[string]';$script:featureBootStamp='boot-before';$script:fixtureInstallerSnapshot=[pscustomobject]@{Utc='fixture';Items=@()}
        $featureRoot=Join-Path $root 'feature-state';[void][IO.Directory]::CreateDirectory($featureRoot)
        $script:assistiveLoopPaths=[pscustomobject]@{Root=$featureRoot;State=(Join-Path $featureRoot 'state.json');Journal=(Join-Path $featureRoot 'journal.jsonl')}
        $script:assistiveLoopState=[pscustomobject]@{PairId='pair-feature-loop';TargetFingerprint=('c'*64);PlanHash=('b'*64);RunId=[Guid]::NewGuid().ToString();Sequence=0;JournalHash=('0'*64);Items=@();PendingOperations=@();Cutover=$null;ManifestHash='';Generation=0;Stage='NotStarted';AssistiveFileResults=@()}
        Set-Item Function:\Get-WindowsFeature -Value {param([string]$Name)$script:featureTrace.Add('Get-WindowsFeature');[pscustomobject]@{Name=$Name;Installed=$script:featureInstalled}}
        Set-Item Function:\Install-WindowsFeature -Value {param([string]$Name,[string]$ErrorAction)$script:featureTrace.Add('Install-WindowsFeature');$script:featureInstallCalls++;$script:featureInstalled=$true;[pscustomobject]@{Success=$true;ExitCode='SuccessRestart';RestartNeeded='Yes'}}
        Set-Item Function:\Get-WsmBootStamp -Value {$script:featureTrace.Add('Get-WsmBootStamp');$script:featureBootStamp}
        Set-Item Function:\Get-WsmInstallerSnapshot -Value {$script:featureTrace.Add('Get-WsmInstallerSnapshot count='+$script:fixtureInstallerSnapshot.Items.Count+' type='+$script:fixtureInstallerSnapshot.Items.GetType().FullName);$script:fixtureInstallerSnapshot}
        $script:featureDebugError='none';Set-Item Function:\Assert-WsmInstallerPolicy -Value {param($Desired)try{& $script:nativeAssistiveInstallerPolicy $Desired}catch{$script:featureDebugError='Policy: '+$_.Exception.ToString();throw}}
        Set-Item Function:\Test-WsmInstallerConsumers -Value {param($Desired,$Receipt,[string]$Phase='Staged')try{$script:featureDebugError='Inputs '+($Desired|ConvertTo-Json -Depth 4 -Compress)+' receipt '+($Receipt|ConvertTo-Json -Depth 4 -Compress);& $script:nativeAssistiveInstallerConsumers $Desired $Receipt $Phase}catch{$script:featureDebugError+=' failure '+$_.Exception.ToString();throw}}
        Set-Item Function:\Get-WsmAdapterState -Value {param($Spec)$script:featureTrace.Add('Get-WsmAdapterState/'+$Spec.Adapter);if($Spec.Adapter -ceq 'WindowsFeature'){$feature=Get-WindowsFeature -Name $Spec.Desired.Name;[pscustomobject]@{Exists=[bool]$feature.Installed;Name=$feature.Name}}elseif($Spec.PSObject.Properties['SettingTransition']){[pscustomobject]@{Exists=$script:settingState.Exists;Value=$script:settingState.Value;ValueKind=$script:settingState.ValueKind}}else{& $script:nativeAssistiveAdapterState $Spec}}
        $featureItem=[pscustomobject]@{ItemId=$script:testItemId;Name='Feature fixture';Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='WindowsFeature';Desired=[pscustomobject]@{Name='Fixture-Feature';IsolationEvidence='Owner-approved isolated maintenance window.';SideEffects=@()}}}
        $featurePackage=[pscustomobject]@{Root=$root;SHA256=('a'*64);PlanHash=('b'*64);Plan=[pscustomobject]@{SchemaVersion=3;Items=@($featureItem)};Manifest=[pscustomobject]@{PairId='pair-feature-loop';PlanHash=('b'*64);Generation=21;Final=$true;Target=[pscustomobject]@{Fingerprint=('c'*64)}}}
        $script:assistiveLoopPackage=$featurePackage;$script:assistiveLoopState.ManifestHash='';$script:assistiveLoopState.Generation=0;$script:assistiveLoopState.Stage='NotStarted';$script:assistiveLoopState.Items=@();$script:assistiveLoopState.PendingOperations=@()
        $existingFeatureRoot=Join-Path $root 'feature-existing-state';[void][IO.Directory]::CreateDirectory($existingFeatureRoot);$script:assistiveLoopPaths=[pscustomobject]@{Root=$existingFeatureRoot;State=(Join-Path $existingFeatureRoot 'state.json');Journal=(Join-Path $existingFeatureRoot 'journal.jsonl')};$script:featureInstalled=$true
        $existingFeaturePreview=Get-WsmAssistiveRestorePreview -ManifestPath 'fixture' -ExpectedHash ('a'*64) -StateDirectory $existingFeatureRoot -AssistiveDecisionReceiptPath 'fixture-receipt' -AssistiveDecisionReceiptHash ('4'*64) -AssistiveTargetSnapshotPath 'fixture-snapshot'
        Check ($existingFeaturePreview.Rows[0].Status -ceq 'Ready' -and $existingFeaturePreview.Rows[0].Action -ceq 'VerifyExistingFeature') 'Already-installed approved WindowsFeature was not offered as a verified existing dependency.'
        $existingFeatureResult=Invoke-WsmAssistiveRestore $featurePackage ('a'*64) $existingFeatureRoot @{} @{} $null @() 'fixture-receipt' ('4'*64) 'fixture-snapshot' $existingFeaturePreview
        $existingFeatureBaseline=Join-Path $existingFeatureRoot ($script:testItemId+'.installer-baseline.json')
        Check ($existingFeatureResult.Results[0].Status -ceq 'Succeeded' -and -not $existingFeatureResult.Items[0].CreatedByTool -and $existingFeatureResult.Items[0].OwnershipChannel -ceq 'Preexisting' -and $script:featureInstallCalls -eq 0 -and -not [IO.File]::Exists($existingFeatureBaseline)) 'Preinstalled WindowsFeature was installed again, claimed as created, or given installer rollback ownership.'
        $script:assistiveLoopPaths=[pscustomobject]@{Root=$featureRoot;State=(Join-Path $featureRoot 'state.json');Journal=(Join-Path $featureRoot 'journal.jsonl')};$script:featureInstalled=$false;$script:assistiveLoopState=[pscustomobject]@{PairId='pair-feature-loop';TargetFingerprint=('c'*64);PlanHash=('b'*64);RunId=[Guid]::NewGuid().ToString();Sequence=0;JournalHash=('0'*64);Items=@();PendingOperations=@();Cutover=$null;ManifestHash='';Generation=0;Stage='NotStarted';AssistiveFileResults=@()}
        $featurePreview=Get-WsmAssistiveRestorePreview -ManifestPath 'fixture' -ExpectedHash ('a'*64) -StateDirectory $featureRoot -AssistiveDecisionReceiptPath 'fixture-receipt' -AssistiveDecisionReceiptHash ('4'*64) -AssistiveTargetSnapshotPath 'fixture-snapshot'
        Check ($featurePreview.Rows[0].Status -ceq 'Ready') 'WindowsFeature Assistive preview did not pass the isolated native capability boundary.'
        $featureApplied=Invoke-WsmAssistiveRestore $featurePackage ('a'*64) $featureRoot @{} @{} $null @() 'fixture-receipt' ('4'*64) 'fixture-snapshot' $featurePreview
        $featureRecord=$featureApplied.Items[0];$baselinePath=Join-Path $featureRoot ($script:testItemId+'.installer-baseline.json')
        $featureError='none';if($Error.Count){$featureError=[string]$Error[0].Exception.Message}
        Check ($featureApplied.Stage -ceq 'RebootRequired' -and $featureRecord.Status -ceq 'RebootRequired' -and $featureRecord.InstallerResult.NativeResult -ceq 'SuccessRestart' -and $featureRecord.InstallerResult.RestartNeeded -ceq 'Yes') ('WindowsFeature Assistive consumer failed to persist restart result and RebootRequired state: '+($featureApplied|ConvertTo-Json -Depth 10 -Compress)+' error='+$featureError+' inner='+$script:featureDebugError+' trace='+(@($script:featureTrace)-join ','))
        Check ([IO.File]::Exists($baselinePath) -and (Get-FileHash -LiteralPath $baselinePath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $featureRecord.InstallerBaselineHash -and $featureRecord.InstallerBaselinePath -ceq $baselinePath) 'WindowsFeature installer baseline was not durably written and hash-bound before native installation.'
        $featurePreview=Get-WsmAssistiveRestorePreview -ManifestPath 'fixture' -ExpectedHash ('a'*64) -StateDirectory $featureRoot -AssistiveDecisionReceiptPath 'fixture-receipt' -AssistiveDecisionReceiptHash ('4'*64) -AssistiveTargetSnapshotPath 'fixture-snapshot'
        Check ($featurePreview.Rows[0].Status -ceq 'DeferredSoftware' -and $script:featureInstallCalls -eq 1) 'WindowsFeature retry was allowed before a changed boot stamp proved reboot completion.'
        $featureBootBefore=$featureRecord.BootBefore
        $featureOperation=[pscustomobject]@{ItemId=$script:testItemId;Phase='AssistiveAdapterCreating';Adapter='WindowsFeature';ManifestHash=('a'*64);Generation=21;Before=[pscustomobject]@{Exists=$false};DesiredHash=(Get-WsmHashText ($featureItem.MigrationSpec.Desired|ConvertTo-Json -Depth 40 -Compress));AbsentBefore=$true;BootBefore=$featureBootBefore;InstallerBaselinePath=$baselinePath;InstallerBaselineHash=$featureRecord.InstallerBaselineHash;FolderCreateIntents=@();AuxiliaryOwnership=@()}
        $featureRepairState=[pscustomobject]@{Items=@();PendingOperations=@($featureOperation);Stage='Running'}
        $script:featureBootStamp=$featureBootBefore
        Complete-WsmAssistiveOperationRepair $featureItem $featureOperation $featurePackage ([pscustomobject]@{Root=$featureRoot;State=$script:assistiveLoopPaths.State;Journal=$script:assistiveLoopPaths.Journal}) $featureRepairState | Out-Null
        Check ($featureRepairState.Stage -ceq 'RebootRequired' -and $featureRepairState.Items[0].Status -ceq 'RebootRequired') 'Interrupted WindowsFeature recovery did not reconstruct the durable RebootRequired stage.'
        $script:featureBootStamp='boot-after';$featurePreview=Get-WsmAssistiveRestorePreview -ManifestPath 'fixture' -ExpectedHash ('a'*64) -StateDirectory $featureRoot -AssistiveDecisionReceiptPath 'fixture-receipt' -AssistiveDecisionReceiptHash ('4'*64) -AssistiveTargetSnapshotPath 'fixture-snapshot'
        Check ($featurePreview.Rows[0].Status -ceq 'Ready') 'WindowsFeature retry remained blocked after the simulated boot stamp changed.'
        $featureRetry=Invoke-WsmAssistiveRestore $featurePackage ('a'*64) $featureRoot @{} @{} $null @() 'fixture-receipt' ('4'*64) 'fixture-snapshot' $featurePreview
        Check ($featureRetry.Results[0].Status -ceq 'Succeeded' -and $featureRetry.Stage -ceq 'Succeeded' -and $script:featureInstallCalls -eq 1 -and $featureRetry.Items[0].InstallerResult.NativeResult -ceq 'SuccessRestart') 'WindowsFeature post-reboot retry reinstalled the role or lost the original native restart receipt.'

        # Drive the real setting-transition coordinator from a schema-3
        # Assistive item; only the machine setting native snapshot/write API is
        # replaced so the host registry is untouched.
        $script:settingState=[pscustomobject]@{Exists=$true;Value='fixture-before';ValueKind='String'}
        Set-Item Function:\Get-WsmSettingNativeSnapshot -Value {param($Transition)$script:settingState.PSObject.Copy()}
        Set-Item Function:\Set-WsmSettingNativeState -Value {param($Transition,$State)$script:settingState=[pscustomobject]@{Exists=[bool]$State.Exists;Value=[string]$State.Value;ValueKind=[string]$State.ValueKind}}
        $transition=New-WsmSettingTransition -Adapter MachineEnvironment -Action UpdateReviewed -Name NLS_LANG -Before ([pscustomobject]@{Exists=$true;Value='fixture-before';ValueKind='String'}) -After ([pscustomobject]@{Exists=$true;Value='fixture-after';ValueKind='String'}) -Owner 'Fixture owner' -Evidence 'Isolated consumer test with native setting API substituted.' -OwnerReviewHash ('9'*64)
        $settingItem=[pscustomobject]@{ItemId=$script:testItemId;Name='Reviewed setting';Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='MachineEnvironment';Desired=[pscustomobject]@{Name='NLS_LANG';Value='fixture-after'};SettingTransition=$transition}}
        $settingPackage=[pscustomobject]@{Root=$root;SHA256=('a'*64);PlanHash=('b'*64);Plan=[pscustomobject]@{SchemaVersion=3;Items=@($settingItem)};Manifest=[pscustomobject]@{PairId='pair-setting-loop';PlanHash=('b'*64);Generation=22;Final=$true;Target=[pscustomobject]@{Fingerprint=('c'*64)}}}
        $settingRoot=Join-Path $root 'setting-state';[void][IO.Directory]::CreateDirectory($settingRoot);$script:assistiveLoopPaths=[pscustomobject]@{Root=$settingRoot;State=(Join-Path $settingRoot 'state.json');Journal=(Join-Path $settingRoot 'journal.jsonl')};$script:assistiveLoopPackage=$settingPackage
        $script:assistiveLoopState=[pscustomobject]@{PairId='pair-setting-loop';TargetFingerprint=('c'*64);PlanHash=('b'*64);RunId=[Guid]::NewGuid().ToString();Sequence=0;JournalHash=('0'*64);Items=@();PendingOperations=@();Cutover=$null;ManifestHash='';Generation=0;Stage='NotStarted';AssistiveFileResults=@()}
        $settingPreview=Get-WsmAssistiveRestorePreview -ManifestPath 'fixture' -ExpectedHash ('a'*64) -StateDirectory $settingRoot -AssistiveDecisionReceiptPath 'fixture-receipt' -AssistiveDecisionReceiptHash ('4'*64) -AssistiveTargetSnapshotPath 'fixture-snapshot'
        Check ($settingPreview.Rows[0].Action -ceq 'ApplySettingTransition' -and $settingPreview.Rows[0].Status -ceq 'Ready') 'Reviewed MachineEnvironment transition did not reach the Assistive preview consumer.'
        $settingApplied=Invoke-WsmAssistiveRestore $settingPackage ('a'*64) $settingRoot @{} @{} $null @() 'fixture-receipt' ('4'*64) 'fixture-snapshot' $settingPreview
        Check ($script:settingState.Value -ceq 'fixture-after' -and $settingApplied.Results[0].Status -ceq 'Succeeded' -and $settingApplied.Items[0].SettingTransitionReceipt.Status -ceq 'Applied') 'Assistive restore did not invoke the real transition coordinator and native exact readback path.'
        Check ((Test-WsmSettingTransitionRecordOwnership $settingApplied.Items[0] $settingItem.MigrationSpec ('c'*64)) -and $settingApplied.Items[0].UpdatedByTool -and -not $settingApplied.Items[0].CreatedByTool) 'Assistive setting transition did not retain its typed receipt and update ownership proof.'

        $replayPair='pair-replay-feature';$replayRoot=Join-Path $root 'replay-state';[void][IO.Directory]::CreateDirectory($replayRoot);$replayPaths=[pscustomobject]@{Root=$replayRoot;State=(Join-Path $replayRoot 'state.json');Journal=(Join-Path $replayRoot 'journal.jsonl')};$script:assistiveLoopPaths=$replayPaths;$replayRun=[Guid]::NewGuid().ToString();$startRow=[pscustomobject][ordered]@{Sequence=1;PreviousHash=('0'*64);RunId=$replayRun;PairId=$replayPair;Utc=(Get-WsmUtc);Action='AssistiveRestoreStarted';ItemId='';Detail=[pscustomobject]@{ManifestHash=('a'*64);Generation=21}};$startText=$startRow|ConvertTo-Json -Depth 15 -Compress;$startHash=Get-WsmHashText $startText;$recoveredRow=[pscustomobject][ordered]@{Sequence=2;PreviousHash=$startHash;RunId=$replayRun;PairId=$replayPair;Utc=(Get-WsmUtc);Action='AssistiveAdapterRecovered';ItemId=$script:testItemId;Detail=[pscustomobject]@{ItemId=$script:testItemId;Status='RebootRequired';CreatedByTool=$true}};$recoveredText=$recoveredRow|ConvertTo-Json -Depth 15 -Compress;$recoveredHash=Get-WsmHashText $recoveredText
        [IO.File]::WriteAllText($replayPaths.Journal,$startText+[Environment]::NewLine+$recoveredText+[Environment]::NewLine)
        $replayState=[pscustomobject]@{SchemaVersion=1;ToolVersion='fixture';Kind='OperationState';BatchId='fixture';PairId=$replayPair;TargetFingerprint=('c'*64);PlanHash=('b'*64);RunId=$replayRun;ManifestHash=('a'*64);Generation=21;Stage='Running';Sequence=1;ResultSequence=0;JournalHash=$startHash;JournalSegment=0;Items=@();Evidence=@();Cutover=$null;PendingOperations=@()};Write-WsmJson $replayPaths.State $replayState
        Restore-WsmJournalCheckpoint $replayPaths $replayState
        Check ((Read-WsmJson $replayPaths.State).Stage -ceq 'RebootRequired') 'Journal checkpoint replay did not retain RebootRequired after interrupted feature recovery.'
        Set-Item Function:\Get-WsmInstallerSnapshot -Value $script:nativeAssistiveInstallerSnapshot
        Set-Item Function:\Get-WsmBootStamp -Value $script:nativeAssistiveBootStamp
        Set-Item Function:\Get-WsmSettingNativeSnapshot -Value $script:nativeAssistiveSettingSnapshot
        Set-Item Function:\Set-WsmSettingNativeState -Value $script:nativeAssistiveSetSetting
        Set-Item Function:\Test-WsmInstallerConsumers -Value $script:nativeAssistiveInstallerConsumers
        Set-Item Function:\Assert-WsmInstallerPolicy -Value $script:nativeAssistiveInstallerPolicy
        Remove-Item Function:\Install-WindowsFeature -ErrorAction SilentlyContinue
        Remove-Item Function:\Get-WindowsFeature -ErrorAction SilentlyContinue
        Set-Item Function:\Get-WsmAssistiveRestoreDecision -Value $script:nativeAssistiveDecisionForLoop
        Set-Item Function:\Test-WsmMigrationPackage -Value $script:nativeAssistiveTestPackageForLoop
        Set-Item Function:\Assert-WsmMigrationHost -Value $script:nativeAssistiveAssertHostForLoop
        Set-Item Function:\Get-WsmMachineIdentity -Value $script:nativeAssistiveMachineIdentityForLoop
        Set-Item Function:\Get-WsmAssistiveNonCResultRows -Value $script:nativeAssistiveNonCRowsForLoop
        Set-Item Function:\Assert-WsmAssistiveReceiptFresh -Value $script:nativeAssistiveAssertFreshForLoop
        Set-Item Function:\Register-WsmAssistivePackageMaterials -Value $script:nativeAssistiveRegisterJobForLoop
        Set-Item Function:\Get-WsmOperationPaths -Value $script:originalGetWsmOperationPaths
        Set-Item Function:\Get-WsmOperationState -Value $script:originalGetWsmOperationState
        Set-Item Function:\Get-WsmAssistiveReservations -Value $script:nativeAssistiveReservationsForLoop
        Set-Item Function:\Confirm-WsmOutputStateCheckpoint -Value $script:nativeAssistiveCheckpointForLoop
        Set-Item Function:\Invoke-WsmIisConfigRestore -Value $script:nativeAssistiveIisWriteForLoop
        Set-Item Function:\New-WsmIisManager -Value $script:nativeAssistiveNewIisManagerForLoop
        Set-Item Function:\Get-WsmAdapterState -Value $script:nativeAssistiveAdapterState

        $deltaItem=[pscustomobject]@{ItemId=$script:testItemId;Name='preview single';Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='FileScope';TargetPath=(Join-Path $root 'delta-target')}}
        $deltaBase=[pscustomobject]@{SHA256=('e'*64);Manifest=[pscustomobject]@{PairId='0123456789abcdef0123456789abcdef';Generation=4};Plan=[pscustomobject]@{SchemaVersion=3;Items=@($deltaItem)}}
        $deltaCurrent=[pscustomobject]@{SHA256=('f'*64);Manifest=[pscustomobject]@{PairId=$deltaBase.Manifest.PairId;Generation=5};Plan=[pscustomobject]@{SchemaVersion=3;Assistive=[pscustomobject]@{ApprovedItemIds=@($script:testItemId)};Items=@($deltaItem)}}
        $deltaBaseState=[pscustomobject]@{PairId=$deltaBase.Manifest.PairId;ManifestHash=$deltaBase.SHA256;Generation=4;Cutover=$null;PendingOperations=@();Items=@()}
        $deltaGate=Assert-WsmAssistiveDeltaBaseOwnership $deltaCurrent $deltaBase $deltaBaseState
        Check (-not $deltaGate.Ready -and @($deltaGate.MissingOwnedItemIds) -contains $script:testItemId) 'Delta fallback allowed reconstruction without exact durable FileScope ownership.'
        $deltaCommand=Get-Command Invoke-WsmArtifactDeltaRestore
        Check ($deltaCommand.Parameters.ContainsKey('AssistiveDecisionReceiptPath') -and $deltaCommand.Parameters.ContainsKey('FullPackageManifestPath') -and $deltaCommand.Parameters.ContainsKey('NonCResultPath')) 'Public delta restore does not expose the Assistive full-package fallback receipt/result seam.'

        $challengeWorkspace=Join-Path $root 'service-challenge-workspace';$challengeState=Join-Path $challengeWorkspace 'pairs';$challengePair=[Guid]::NewGuid().ToString('D');$challengeOperation=[Guid]::NewGuid().ToString('D');$challengePlanHash='1'*64;$challengeManifestHash='2'*64;$challengePreviewHash='3'*64;$challengeFingerprint='4'*64
        $challengePackage=[pscustomobject]@{Manifest=[pscustomobject]@{PairId=$challengePair;BatchId=[Guid]::NewGuid().ToString('D');PlanHash=$challengePlanHash;Target=[pscustomobject]@{Fingerprint=$challengeFingerprint}};Plan=[pscustomobject]@{SchemaVersion=3;Items=@()}}
        $challengePaths=Get-WsmOperationPaths -StateDirectory $challengeState -PairId $challengePair;$challengeOperationState=Get-WsmOperationState -Paths $challengePaths -Package $challengePackage
        $challengeItemCreated='5'*64;$challengeItemOwned='6'*64;$challengeServiceCreated='FixtureChallengeNew';$challengeServiceOwned='FixtureChallengeExisting';$challengeReservations=@();$challengeResourceRegistry=Get-WsmAssistiveResourceRegistry $challengeState
        foreach($binding in @(@($challengeServiceCreated,$challengeItemCreated,$true),@($challengeServiceOwned,$challengeItemOwned,$false))){$resourceKey=Get-WsmHashText (Get-WsmAssistiveTypedResourceIdentity $challengeFingerprint 'Service' $binding[0]);$challengeReservations+=@([pscustomobject]@{ResourceKey=$resourceKey;ItemId=$binding[1];Created=[bool]$binding[2]});$owner=[pscustomobject]@{PairId=$challengePair;ItemId=$binding[1];Channel='C';ResourceKind='Service';ResourceName=$binding[0];TargetFingerprint=$challengeFingerprint;SourceHash=('7'*64);OperationId=$challengeOperation;ActiveOperationId=$challengeOperation;ChallengeState='WaitingForInput';ConsumerRefs=@($binding[1]);Reason='Fixture';ReservedUtc=(Get-WsmUtc);Prior=@();Desired=$null;Readback=$null;Undo=$null;DriftStatus='Unverified';EvidenceHash=''};$challengeResourceRegistry.Resources+=@([pscustomobject]@{ResourceKey=$resourceKey;PhysicalIdentity='TypedTarget|fixture';CanonicalPhysicalPath=$binding[0];ResourceKind='Service';ResourceName=$binding[0];TargetFingerprint=$challengeFingerprint;Path=$binding[0];ProviderId='TypedTarget';Owners=@($owner);LastReleaseReason='';LastReleaseUtc=''})}
        Write-WsmAssistiveResourceRegistry $challengeState $challengeResourceRegistry | Out-Null
        $challengeRecord=[pscustomobject][ordered]@{State='WaitingForInput';ParentOperationId=$challengeOperation;PairId=$challengePair;Role='Target';Actor='FixtureActor';SessionId='FixtureSession';ContextId='InteractiveTargetRestore';Revision=8;ManifestHash=$challengeManifestHash;Generation=1;PreviewHash=$challengePreviewHash;RequiredSecretRefs=@('ServiceSecretA');ServiceReservations=$challengeReservations;CreatedUtc=(Get-WsmUtc);UpdatedUtc=(Get-WsmUtc)}
        $challengeAttempt=[pscustomobject][ordered]@{OperationId=$challengeOperation;ManifestHash=$challengeManifestHash;Generation=1;DecisionReceiptHash=('8'*64);TargetSnapshotHash=('a'*64);WizardPreviewHash=$challengePreviewHash;SelectedItemIds=@($challengeItemCreated,$challengeItemOwned);Status='WaitingForInput';MaterialIds=@();ItemResults=@()};$challengeOperationState|Add-Member NoteProperty RestoreAttempt $challengeAttempt -Force;$challengeOperationState|Add-Member NoteProperty Stage 'WaitingForInput' -Force
        Set-Item Function:\Add-WsmJournal -Value $script:originalAddWsmJournal
        $challengeOperationState | Add-Member NoteProperty AssistiveServiceChallenge $challengeRecord -Force
        if([string]::IsNullOrWhiteSpace([string]$challengePaths.State)){throw ('Fixture operation state path is empty; paths='+($challengePaths|ConvertTo-Json -Compress -Depth 3)+'; workspace='+$challengeState)}
        Write-WsmJson -Path $challengePaths.State -Data $challengeOperationState;Add-WsmJournal $challengePaths $challengeOperationState 'AssistiveServiceCredentialChallengeWaiting' '' $challengeRecord
        Reject {Cancel-WsmAssistiveServiceCredentialChallenge $challengeState $challengePair $challengeOperation ('9'*64)} 'Service challenge cancellation accepted a different preview binding.'
        Reject {Takeover-WsmAssistiveServiceCredentialChallenge -StateDirectory $challengeState -PairId $challengePair -OperationId $challengeOperation -PreviewHash $challengePreviewHash -Actor 'FixtureActor2' -SessionId 'FixtureSession2' -ContextId 'InteractiveTargetRestore' -Revision 8} 'Service challenge takeover proceeded without explicit confirmation.'
        Reject {Takeover-WsmAssistiveServiceCredentialChallenge -StateDirectory $challengeState -PairId $challengePair -OperationId $challengeOperation -PreviewHash ('9'*64) -Actor 'FixtureActor2' -SessionId 'FixtureSession2' -ContextId 'InteractiveTargetRestore' -Revision 8 -ConfirmTakeover} 'Service challenge takeover accepted a stale preview.'
        [void](Takeover-WsmAssistiveServiceCredentialChallenge -StateDirectory $challengeState -PairId $challengePair -OperationId $challengeOperation -PreviewHash $challengePreviewHash -Actor 'FixtureActor2' -SessionId 'FixtureSession2' -ContextId 'InteractiveTargetRestore' -Revision 8 -ConfirmTakeover)
        $takenOverState=Read-WsmJson $challengePaths.State;Check ($takenOverState.AssistiveServiceChallenge.State -ceq 'WaitingForInput' -and $takenOverState.AssistiveServiceChallenge.ParentOperationId -ceq $challengeOperation -and $takenOverState.AssistiveServiceChallenge.Actor -ceq 'FixtureActor2' -and $takenOverState.RestoreAttempt.OperationId -ceq $challengeOperation -and $takenOverState.RestoreAttempt.Status -ceq 'WaitingForInput' -and -not $takenOverState.RestoreAttempt.PSObject.Properties['CompletedUtc']) 'Explicit takeover created a new operation, completed the parent, or lost the same durable challenge binding.'
        $recoveryState=Read-WsmJson $challengePaths.State;$recoveryState.Stage='Running';$recoveryState.RestoreAttempt.Status='Running';$recoveryState.AssistiveServiceChallenge.State='Running';Reject {Test-WsmAssistiveServiceChallengePreWriteRecovery $challengeState $recoveryState $challengeOperation} 'A Running parent without its matching durable restore-start journal was auto-recovered.';Write-WsmJson $challengePaths.State $recoveryState;Add-WsmJournal $challengePaths $recoveryState 'AssistiveRestoreStarted' '' $recoveryState.RestoreAttempt
        $recoveryReadback=Test-WsmAssistiveServiceChallengePreWriteRecovery $challengeState $recoveryState $challengeOperation;Check ($recoveryReadback.SafeToTakeOver -and -not $recoveryReadback.NativeItemStarted -and $recoveryReadback.PendingOperations -eq 0) 'A consistent Running parent with no native item start was not recognized as a recoverable pre-write crash.'
        $pendingRecovery=$recoveryState.PSObject.Copy();$pendingRecovery.PendingOperations=@([pscustomobject]@{OperationId=[guid]::NewGuid().ToString('D')});Reject {Test-WsmAssistiveServiceChallengePreWriteRecovery $challengeState $pendingRecovery $challengeOperation} 'Pre-write crash takeover ignored a pending native operation intent.'
        [void](Takeover-WsmAssistiveServiceCredentialChallenge -StateDirectory $challengeState -PairId $challengePair -OperationId $challengeOperation -PreviewHash $challengePreviewHash -Actor 'FixtureActor3' -SessionId 'FixtureSession3' -ContextId 'InteractiveTargetRestore' -Revision 8 -ConfirmTakeover)
        $recoveredState=Read-WsmJson $challengePaths.State;Check ($recoveredState.AssistiveServiceChallenge.State -ceq 'WaitingForInput' -and $recoveredState.AssistiveServiceChallenge.ParentOperationId -ceq $challengeOperation -and $recoveredState.AssistiveServiceChallenge.LastPreWriteRecovery.SafeToTakeOver -and $recoveredState.RestoreAttempt.Status -ceq 'WaitingForInput' -and -not $recoveredState.RestoreAttempt.PSObject.Properties['CompletedUtc']) 'Safe pre-write takeover did not return the same incomplete TargetRestore parent to WaitingForInput.'
        [void](Cancel-WsmAssistiveServiceCredentialChallenge $challengeState $challengePair $challengeOperation $challengePreviewHash)
        $cancelledChallenge=Read-WsmJson $challengePaths.State;Check ($cancelledChallenge.AssistiveServiceChallenge.State -ceq 'Cancelled' -and $cancelledChallenge.Stage -ceq 'Cancelled' -and $cancelledChallenge.RestoreAttempt.Status -ceq 'Cancelled') ('Service challenge cancellation was not durable in operation/parent state: challenge='+$cancelledChallenge.AssistiveServiceChallenge.State+' stage='+$cancelledChallenge.Stage+' attempt='+$cancelledChallenge.RestoreAttempt.Status)
        $cancelledRegistry=Get-WsmAssistiveResourceRegistry $challengeState;$createdReservationRecord=@($cancelledRegistry.Resources | Where-Object ResourceKey -CEQ $challengeReservations[0].ResourceKey);Check ($createdReservationRecord.Count -eq 1 -and @($createdReservationRecord[0].Owners).Count -eq 0) 'Cancelling a newly created challenge reservation did not revoke its owner.'
        $preservedOwner=@($cancelledRegistry.Resources | Where-Object ResourceKey -CEQ $challengeReservations[1].ResourceKey)[0].Owners[0];Check ($preservedOwner -and -not $preservedOwner.ActiveOperationId -and $preservedOwner.ChallengeState -ceq 'Released') 'Cancelling a challenge removed or left active a preexisting ownership reservation.'
        Reject {Cancel-WsmAssistiveServiceCredentialChallenge $challengeState $challengePair $challengeOperation $challengePreviewHash} 'Cancelled service challenge was replayable.'
        Write-Host ('PASS: '+$script:checks+' Assistive file ownership, per-file conflict, typed IIS mapping and safe manual-gap checks.')
    } $root $helper
} finally {if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force}}
