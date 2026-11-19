<#
.SYNOPSIS
    Exercises shared VM-command failure envelopes without a Hyper-V guest.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RootPath 'Common.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Common.ps1 does not parse: $($errors -join '; ')" }
$definition = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-VmCommand'
        }, $true))
if ($definition.Count -ne 1) { throw 'Expected one Invoke-VmCommand definition.' }
. ([scriptblock]::Create($definition[0].Extent.Text))
$state = @{ Failure = ''; Logs = [System.Collections.Generic.List[string]]::new() }
$Common = [pscustomobject]@{ LocalAdmin = [pscredential]::Empty }
function Write-Log {
    param($Text, [switch]$LogOnly, [switch]$Failure, [switch]$Verbose)
    if ($state.Failure -eq 'Logging') { throw 'Fixture log write denied' }
    $state.Logs.Add("$Text")
}
function Get-VmSession {
    param($VmName, $VmDomainName, $VmDomainAccount, $ShowVMSessionError, $MaxRetries, $LocalOnly, $RequireDomainIdentity, $Diagnostics, $Quiet)
    switch ($state.Failure) {
        'SessionLookup' { throw 'Fixture session lookup failure' }
        'Unavailable' {
            $Diagnostics.LastError = 'Fixture session unavailable'
            return $null
        }
        default { [pscustomobject]@{ Runspace = $null } }
    }
}
function Enter-VmSessionInflight {
    param($Session, $DisplayName)
    if ($state.Failure -eq 'Inflight') { throw 'Fixture inflight registration failure' }
}
function Exit-VmSessionInflight {
    param($Token)
    if ($state.Failure -eq 'Cleanup') { throw 'Fixture inflight cleanup failure' }
}
function Invoke-Command {
    [CmdletBinding()]
    param($Session, $ScriptBlock)
    if ($state.Failure -eq 'GuestCall') { throw 'Fixture guest execution failure' }
    'fixture-output'
}
function Set-VmSessionPipelineEvent { param($Session, $Kind, $Op) }

$expectedMessages = [ordered]@{
    SessionLookup = 'Fixture session lookup failure'
    Inflight = 'Fixture inflight registration failure'
    Cleanup = 'Fixture inflight cleanup failure'
    Logging = 'Fixture log write denied'
    GuestCall = 'Fixture guest execution failure'
    Unavailable = 'Fixture session unavailable'
}
foreach ($scenario in $expectedMessages.Keys) {
    $state.Failure = $scenario
    $state.Logs.Clear()
    $output = @(Invoke-VmCommand -VmName TEST-VM -VmDomainName example -ScriptBlock { 'fixture-output' } `
            -DisplayName 'Failure regression' -SuppressLog:($scenario -ne 'Logging'))
    if ($output.Count -ne 1 -or $output[0] -is [bool] -or $output[0].CommandResult -or
        $output[0].ErrorDetails -isnot [array] -or
        -not $output[0].ScriptBlockFailed -or ($output[0].ErrorDetails -join ' ') -notmatch [regex]::Escape($expectedMessages[$scenario])) {
        throw "Shared command failure '$scenario' lost its error envelope: $($output | ConvertTo-Json -Depth 4 -Compress)"
    }
}
$state.Failure = ''
$Common.LocalAdmin = $null
$missing = @(Invoke-VmCommand -VmName TEST-VM -VmDomainName example -ScriptBlock { 1 } -SuppressLog)
if ($missing.Count -ne 1 -or $missing[0] -is [bool] -or -not $missing[0].ScriptBlockFailed -or
    ($missing[0].ErrorDetails -join ' ') -notmatch 'credential' -or
    $missing[0].ScriptBlockOutput -notmatch 'credential') { throw 'Missing credentials returned an unexplained bare false.' }
$Common.LocalAdmin = [pscredential]::Empty
$success = @(Invoke-VmCommand -VmName TEST-VM -VmDomainName example -ScriptBlock { 1 } -SuppressLog)
if ($success.Count -ne 1 -or -not $success[0].CommandResult -or $success[0].ScriptBlockFailed -or
    $success[0].ScriptBlockOutput -ne 'fixture-output') { throw 'Successful VM-command behavior regressed.' }
Write-Host 'PASS -- VM-command failures return one failed envelope with error details; successful calls remain unchanged.'
