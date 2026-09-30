<#
.SYNOPSIS
    Verifies Defender tuning is an idempotent no-op when the engine is inactive.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$optimizerPath = Join-Path $root 'baseimagestaging\filesToInject\staging\Optimize-Defender.ps1'

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($optimizerPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    throw "$optimizerPath has $($errors.Count) parse error(s): $($errors -join '; ')"
}

$global:MemLabsDefenderTuningPreferenceCalls = 0
$global:MemLabsDefenderTuningDisabledTasks = New-Object System.Collections.Generic.List[string]

function Get-MpComputerStatus {
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        IsTamperProtected         = $false
        RealTimeProtectionEnabled = $false
        AMRunningMode             = 'Not running'
    }
}

function Get-CimInstance {
    [CmdletBinding()]
    param([string] $ClassName)

    [pscustomobject]@{ ProductType = 3 }
}

function Get-ScheduledTask {
    [CmdletBinding()]
    param([string] $TaskPath)

    @(
        [pscustomobject]@{ TaskName = 'Cache Maintenance'; TaskPath = $TaskPath; State = 'Ready' }
        [pscustomobject]@{ TaskName = 'Scheduled Scan'; TaskPath = $TaskPath; State = 'Disabled' }
    )
}

function Disable-ScheduledTask {
    [CmdletBinding()]
    param(
        [string] $TaskName,
        [string] $TaskPath
    )

    $global:MemLabsDefenderTuningDisabledTasks.Add("$TaskPath$TaskName")
}

function Get-MpPreference {
    [CmdletBinding()]
    param()

    $global:MemLabsDefenderTuningPreferenceCalls++
    throw 'Get-MpPreference must not run while Defender reports AMRunningMode=Not running.'
}

function Add-MpPreference {
    $global:MemLabsDefenderTuningPreferenceCalls++
    throw 'Add-MpPreference must not run while Defender reports AMRunningMode=Not running.'
}

function Set-MpPreference {
    $global:MemLabsDefenderTuningPreferenceCalls++
    throw 'Set-MpPreference must not run while Defender reports AMRunningMode=Not running.'
}

$result = & $optimizerPath
if (-not $result.Success) {
    throw "Inactive Defender was treated as a tuning failure: $($result.Message)"
}
if ($result.Message -notmatch 'Defender Antivirus is not running; preference tuning is not applicable') {
    throw "Inactive Defender result did not explain the no-op: $($result.Message)"
}
if ($global:MemLabsDefenderTuningPreferenceCalls -ne 0) {
    throw "Inactive Defender invoked $global:MemLabsDefenderTuningPreferenceCalls preference command(s)."
}
if ($global:MemLabsDefenderTuningDisabledTasks.Count -ne 1 -or $global:MemLabsDefenderTuningDisabledTasks[0] -ne '\Microsoft\Windows\Windows Defender\Cache Maintenance') {
    throw "Expected only the enabled Defender scheduled task to be disabled; got [$($global:MemLabsDefenderTuningDisabledTasks -join ', ')]."
}
if (@($result.Applied) -notcontains '1 Defender scheduled task(s) disabled') {
    throw "Inactive Defender result did not report the scheduled task action: $($result.Applied -join '; ')"
}

Write-Host 'Defender inactive-engine tuning checks passed.'
