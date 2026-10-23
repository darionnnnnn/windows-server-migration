#requires -Version 5.1
# N9h-D1 regression: the Source scan/confirmation writes its content-addressed material under <workspace>\assistive\materials, while the one-click
# backup hands the exporter <workspace>\pairs as the source state directory. The controls writer must read the plan's MaterialReferences from the
# same controlled location the Source wrote them to (the approved Source workspace root), and keep refusing anything outside that workspace.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$module=Import-Module (Join-Path $repo 'src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking 3>$null
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-n9h-d1-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try{
    $checks=& $module {
        param($Root,$Repo)
        $script:Checks=0
        function Check($Condition,[string]$Message){if(-not $Condition){throw ('FAIL: '+$Message)};$script:Checks++}
        function Expect-Throw([scriptblock]$Action,[string]$Pattern,[string]$Message){
            $text='';try{& $Action}catch{$text=[string]$_.Exception.Message}
            Check ($text -and $text -match $Pattern) ($Message+' (message: '+$text+')')
        }
        function Sha([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
        function New-Workspace([string]$Name){
            $workspace=Join-Path $Root $Name
            $state=Join-Path $workspace 'pairs'
            [void][IO.Directory]::CreateDirectory($state)
            # approved snapshot, imported under the state directory at its original reference (Import-WsmWizardApprovedPlan)
            $snapshotBytes=[Text.Encoding]::UTF8.GetBytes('{"snapshot":"'+$Name+'"}')
            $sha=[Security.Cryptography.SHA256]::Create();try{$snapshotHash=[BitConverter]::ToString($sha.ComputeHash($snapshotBytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
            $snapshotRelative='assistive/snapshots/'+$snapshotHash+'.json'
            $snapshotPath=Join-Path $state $snapshotRelative.Replace('/','\')
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($snapshotPath));[IO.File]::WriteAllBytes($snapshotPath,$snapshotBytes)
            # confirmation material written by the Source scan under the workspace root
            $confirmationBytes=[Text.Encoding]::UTF8.GetBytes('{"confirmation":"'+$Name+'"}')
            $confirmationPath=Join-Path $workspace 'assistive\materials\source-candidate\tmp\confirmation.json'
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($confirmationPath));[IO.File]::WriteAllBytes($confirmationPath,$confirmationBytes)
            $confirmationHash=Sha $confirmationPath
            $materialRelative='assistive/materials/source-candidate/'+$confirmationHash+'/confirmation.json'
            $materialPath=Join-Path $workspace $materialRelative.Replace('/','\')
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($materialPath));[IO.File]::Move($confirmationPath,$materialPath)
            $plan=[pscustomobject]@{Assistive=[pscustomobject]@{ContractVersion=2;SourceSnapshotHash=$snapshotHash;MaterialReferences=@([pscustomobject]@{Reference=$materialRelative;SHA256=$confirmationHash;CreatedUtc=[DateTime]::UtcNow.ToString('o')});DiscoveryAuthority=[pscustomobject]@{SourceSnapshotReference=[pscustomobject]@{Reference=$snapshotRelative;SHA256=$snapshotHash;CreatedUtc=[DateTime]::UtcNow.ToString('o')}}}}
            [pscustomobject]@{Workspace=$workspace;State=$state;Plan=$plan;MaterialPath=$materialPath;MaterialHash=$confirmationHash;SnapshotHash=$snapshotHash}
        }
        function New-Package([string]$Name){$package=Join-Path $Root ('pkg-'+$Name);[void][IO.Directory]::CreateDirectory($package);$package}

        # 1. The real layout: material under the workspace root, state directory = <workspace>\pairs.
        $fx=New-Workspace 'real'
        $package=New-Package 'real'
        $result=Write-WsmOfflineFullSetControls $fx.Plan $fx.State $package $fx.Workspace
        Check ($result.Count -eq 2) 'controls hold the source inventory and the one mandatory material'
        $row=@($result.Rows|Where-Object Kind -ceq 'AssistiveMaterial')
        Check ($row.Count -eq 1 -and $row[0].SHA256 -ceq $fx.MaterialHash -and $row[0].Reference -ceq $fx.Plan.Assistive.MaterialReferences[0].Reference) 'the material row carries the sealed reference and hash'
        Check ((Sha (Join-Path $package ($row[0].Name.Replace('/','\')))) -ceq $fx.MaterialHash) 'the packaged material bytes equal the Source material bytes'
        Check ((Sha (Join-Path $package 'controls\source-inventory.json')) -ceq $fx.SnapshotHash) 'the source inventory still comes from the state directory snapshot'
        Check ((Sha $fx.MaterialPath) -ceq $fx.MaterialHash) 'the Source material is only read, never moved or rewritten'

        # 2. Without the workspace root (the pre-fix call shape) the state directory is the root and the material is not there: the original refusal.
        $legacy=New-Package 'legacy'
        Expect-Throw {Write-WsmOfflineFullSetControls $fx.Plan $fx.State $legacy | Out-Null} 'mandatory source control material is missing' 'resolving against the state directory alone still refuses (no silent fallback to the workspace root)'

        # 3. Containment is kept.
        $outside=New-Package 'outside'
        $otherWorkspace=Join-Path $Root 'other-workspace';[void][IO.Directory]::CreateDirectory($otherWorkspace)
        Expect-Throw {Write-WsmOfflineFullSetControls $fx.Plan $fx.State $outside $otherWorkspace | Out-Null} 'state directory is outside the approved source workspace' 'a workspace root that does not contain the state directory is rejected'
        $escape=New-Workspace 'escape'
        $secret=Join-Path $Root 'outside-secret.txt';[IO.File]::WriteAllText($secret,'outside');$secretHash=Sha $secret
        $escape.Plan.Assistive.MaterialReferences=@([pscustomobject]@{Reference='../outside-secret.txt';SHA256=$secretHash;CreatedUtc=[DateTime]::UtcNow.ToString('o')})
        Expect-Throw {Write-WsmOfflineFullSetControls $escape.Plan $escape.State (New-Package 'escape') $escape.Workspace | Out-Null} 'missing or outside the approved source workspace' 'a reference that climbs out of the workspace is rejected'
        $sibling=New-Workspace 'sibling'
        $siblingEscape=Join-Path $Root 'sibling-evil';[void][IO.Directory]::CreateDirectory($siblingEscape);$evilFile=Join-Path $siblingEscape 'm.txt';[IO.File]::WriteAllText($evilFile,'evil')
        $sibling.Plan.Assistive.MaterialReferences=@([pscustomobject]@{Reference='../sibling-evil/m.txt';SHA256=(Sha $evilFile);CreatedUtc=[DateTime]::UtcNow.ToString('o')})
        Expect-Throw {Write-WsmOfflineFullSetControls $sibling.Plan $sibling.State (New-Package 'sibling') $sibling.Workspace | Out-Null} 'missing or outside the approved source workspace' 'a sibling directory whose name starts with the workspace name is rejected'

        # 4. Hash binding is kept: material changed after approval.
        $tamper=New-Workspace 'tamper'
        [IO.File]::WriteAllText($tamper.MaterialPath,'{"confirmation":"changed"}')
        Expect-Throw {Write-WsmOfflineFullSetControls $tamper.Plan $tamper.State (New-Package 'tamper') $tamper.Workspace | Out-Null} 'changed after approval' 'a changed material is rejected by its sealed hash'

        # 5. The exporter surface carries the parameter to the writer, and the wizard backup passes the workspace root.
        Check ((Get-Command Export-WsmMigrationPackage).Parameters.ContainsKey('MaterialWorkspace') -and (Get-Command Export-WsmMigrationPackageCore).Parameters.ContainsKey('MaterialWorkspace')) 'both export entry points accept MaterialWorkspace'
        $wizardSource=[IO.File]::ReadAllText((Join-Path $Repo 'src\WizardBackup.ps1'))
        Check ($wizardSource -match "SourceStateDirectory=\(Join-Path \`$Workspace 'pairs'\);MaterialWorkspace=\`$Workspace;") 'the one-click backup hands the Source workspace root to the exporter'
        $script:Checks
    } $root $repo
    Write-Host ('PASS: {0} OfflineFullSet material workspace checks (real layout, no silent fallback, containment, sibling prefix, hash binding, wizard wiring)' -f $checks)
}finally{
    if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}
