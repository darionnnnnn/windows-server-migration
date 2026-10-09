#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
& $module {
    function Get-WsmWindowsSettingInventoryEnvironmentStates {
        [pscustomobject]@{
            TNS_ADMIN=[pscustomobject]@{Exists=$true;Value='%ORACLE_HOME%\network\admin';ValueKind='ExpandString'}
            NLS_LANG=[pscustomobject]@{Exists=$true;Value='';ValueKind='String'}
            LDAP_ADMIN=[pscustomobject]@{Exists=$false;Value=$null;ValueKind='None'}
            LOCAL=[pscustomobject]@{Exists=$false;Value=$null;ValueKind='None'}
            ORA_TZFILE=[pscustomobject]@{Exists=$false;Value=$null;ValueKind='None'}
        }
    }
    function Get-WsmSettingTimeZoneSnapshot {
        [pscustomobject]@{Exists=$true;Value='Pacific Standard Time';ValueKind='TimeZoneId';DaylightSaving=[pscustomobject]@{Exists=$true;Value=$true;ValueKind='DWord'}}
    }
    $metadata=Get-WsmWindowsSettingInventoryMetadata
    if($metadata.ControlSource -cne 'Unknown' -or -not $metadata.EnvironmentStatesComplete -or -not $metadata.TimeZoneStateComplete -or $metadata.CoverageGaps.Count){throw 'Successful native capture claimed policy control or omitted completion status.'}
    if($metadata.EnvironmentStates.TNS_ADMIN.Value -cne '%ORACLE_HOME%\network\admin' -or $metadata.EnvironmentStates.TNS_ADMIN.ValueKind -cne 'ExpandString'){throw 'Raw expandable registry value or native kind was lost.'}
    if(-not $metadata.EnvironmentStates.NLS_LANG.Exists -or $metadata.EnvironmentStates.NLS_LANG.Value -cne '' -or $metadata.EnvironmentStates.LDAP_ADMIN.Exists){throw 'Present empty environment value was confused with absence.'}
    if($metadata.TimeZoneState.DaylightSaving.Value -ne $true -or $metadata.TimeZoneState.DaylightSaving.ValueKind -cne 'DWord'){throw 'Native DST prior state was lost.'}
    function Get-WsmWindowsSettingInventoryEnvironmentStates {throw [UnauthorizedAccessException]::new('fixture denied')}
    function Get-WsmSettingTimeZoneSnapshot {throw 'fixture unavailable'}
    $unavailable=Get-WsmWindowsSettingInventoryMetadata
    if($unavailable.EnvironmentStatesComplete -or $unavailable.TimeZoneStateComplete -or $null -ne $unavailable.EnvironmentStates -or $null -ne $unavailable.TimeZoneState -or $unavailable.CoverageGaps.Count -ne 2 -or $unavailable.ControlSource -cne 'Unknown'){throw 'Unavailable native state was represented as absence or local control.'}
    'PASS: native settings metadata preserves raw registry kind, empty/absent and DST state; unavailable capture and policy control remain unknown.'
}
