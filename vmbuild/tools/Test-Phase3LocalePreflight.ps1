<#
.SYNOPSIS
    Verifies Phase 3 locale preflight ordering and Linux-only dispatch.

.DESCRIPTION
    Source-lifts Start-PhaseJobs and shadows its external boundaries. No jobs,
    VMs, DHCP, downloads, or guest sessions are created by this test.
    Run under both PowerShell 7 and Windows PowerShell 5.1.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0
$script:ConfigurationData = $null
$script:MissingHyperVNodes = @()
$script:LocaleProbeCalls = 0
$script:LocaleProbeNames = @()
$script:LocaleIssueVMs = @()
$script:StartedJobs = @()
$script:LogLines = @()
$script:NextJobId = 0
$script:WhatIf = $false

function Assert-Phase3Equal {
    param ($Expected, $Actual, [string] $What)

    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    $status = if ($passed) { 'PASS' } else { 'FAIL' }
    Write-Host ('{0}  {1}' -f $status, $What)
    if (-not $passed) {
        Write-Host "      expected: $Expected"
        Write-Host "      actual:   $Actual"
    }
}

function Import-Phase3TestFunction {
    param ([string] $Path, [string] $Name)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "$Path has $($errors.Count) parse error(s)" }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition, found $($definition.Count)" }
    $sourceDirectory = (Split-Path -Parent $Path).Replace("'", "''")
    $functionText = $definition[0].Extent.Text.Replace('$PSScriptRoot', "'$sourceDirectory'")
    return [scriptblock]::Create($functionText)
}

function Write-Log {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0)] $Message,
        [switch] $Warning,
        [switch] $LogOnly,
        [switch] $Failure,
        [switch] $Success,
        [switch] $OutputStream,
        [switch] $Activity
    )
    $script:LogLines += [string]$Message
}

function Write-Progress2 {
    param ($Activity, $Status, $PercentComplete, [switch] $Completed, [switch] $Log)
}

function Get-ChildItem { @() }
function Get-Command { return $null }
function Get-ConfigurationData { return $script:ConfigurationData }
function Get-List { return @() }
function Get-MissingDscDispatchNodes { return @() }
function Get-MissingHyperVNodes { return @($script:MissingHyperVNodes) }
function Get-VMMacAndDhcpIsolated {
    return [pscustomobject]@{ MacMap = @{}; Reservations = @(); Scoped = $true; MacMs = 0; DhcpMs = 0 }
}
function Get-AllDHCPReservationsIsolated { return @() }
function Test-VmIsLinux {
    param ($Vm)
    return $Vm.osFamily -eq 'Linux' -or $Vm.role -in @('Proxy', 'DHCPRelay', 'LinuxServer', 'LinuxClient')
}
function Get-Phase3LocaleMediaIssues {
    param ($DeployConfig, [string[]] $ApplicableVMNames)
    $script:LocaleProbeCalls++
    $script:LocaleProbeNames = @($ApplicableVMNames)
    return @($script:LocaleIssueVMs | Where-Object { $_ -in $ApplicableVMNames } | ForEach-Object {
            [pscustomobject]@{ VMName = $_; Locale = 'ja-JP'; OperatingSystem = 'Server 2025'; Stage = 'GuestProbe'; Reason = 'test issue' }
        })
}
function Start-Job {
    param ($ScriptBlock, [string] $Name, $ErrorAction, [string] $ErrorVariable, $ArgumentList)
    $script:NextJobId++
    $job = [pscustomobject]@{ Id = $script:NextJobId; Name = $Name }
    $script:StartedJobs += $job
    return $job
}

# These are safety boundaries: neither scenario should reach them.
function Start-ThreadJob { throw 'Unexpected Start-ThreadJob call' }
function Get-VM { throw 'Unexpected Get-VM call' }
function Get-VM2 { throw 'Unexpected Get-VM2 call' }
function Invoke-VmCommand { throw 'Unexpected Invoke-VmCommand call' }
function Start-VM2 { throw 'Unexpected Start-VM2 call' }
function Stop-VM2 { throw 'Unexpected Stop-VM2 call' }
function Wait-ForVm { throw 'Unexpected Wait-ForVm call' }
function Sync-LinuxDhcpRelay { throw 'Unexpected Sync-LinuxDhcpRelay call' }
function Repair-LinuxAdminSshKeyPair { throw 'Unexpected Repair-LinuxAdminSshKeyPair call' }
function Set-OsdClientMacAddresses { throw 'Unexpected Set-OsdClientMacAddresses call' }

$global:Common = [pscustomobject]@{ DevBranch = $false; VerboseEnabled = $false; ConfigPath = $RootPath }
$global:Linux_Configure = { $true }
$global:Proxy_Install = { $true }
$global:VM_Config = { $true }
$global:phaseVmMacSnapshot = $null
$global:DSC_Copied = @()
$global:DSC_CopiedTime = $null

$phasePath = Join-Path $RootPath 'common\Common.Phases.ps1'
. (Import-Phase3TestFunction -Path $phasePath -Name 'Start-PhaseJobs')

function Reset-Phase3TestState {
    $script:LocaleProbeCalls = 0
    $script:LocaleProbeNames = @()
    $script:LocaleIssueVMs = @()
    $script:StartedJobs = @()
    $script:LogLines = @()
    $script:NextJobId = 0
    $global:phaseVmMacSnapshot = $null
    $global:DSC_Copied = @()
    $global:DSC_CopiedTime = $null
}

Reset-Phase3TestState
$script:ConfigurationData = $null
$script:MissingHyperVNodes = @()
$linuxConfig = [pscustomobject]@{
    vmOptions      = [pscustomobject]@{ domainName = 'example.test'; domainNetBiosName = 'EXAMPLE' }
    parameters     = [pscustomobject]@{ ThisMachineName = '' }
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'DC1'; role = 'DC'; domain = 'example.test'; hidden = $true }
        [pscustomobject]@{ vmName = 'LINUX1'; role = 'LinuxClient'; osFamily = 'Linux'; domain = 'example.test'; hidden = $false }
    )
}
$linuxResult = Start-PhaseJobs -Phase 3 -deployConfig $linuxConfig
Assert-Phase3Equal 0 $script:LocaleProbeCalls 'Linux-only Phase 3 does not run the Windows locale media probe'
Assert-Phase3Equal 1 $script:StartedJobs.Count 'Linux-only Phase 3 dispatches exactly one job'
Assert-Phase3Equal 'LINUX1 [LinuxClient] ' $script:StartedJobs[0].Name 'Linux-only Phase 3 dispatches the Linux VM'
Assert-Phase3Equal $true $linuxResult.Applicable 'Linux-only Phase 3 remains applicable'
Assert-Phase3Equal 1 $linuxResult.Success 'Linux-only Phase 3 reports one created job'
Assert-Phase3Equal 0 $linuxResult.Failed 'Linux-only Phase 3 reports no dispatch failure'
Assert-Phase3Equal $false ([bool]$linuxResult.PreflightFailed) 'Linux-only Phase 3 does not report preflight failure'

Reset-Phase3TestState
$script:ConfigurationData = [pscustomobject]@{
    AllNodes = @(
        [pscustomobject]@{ NodeName = '*'; Role = '' }
        [pscustomobject]@{ NodeName = 'JP-SERVER'; Role = 'DomainMember' }
    )
}
$script:MissingHyperVNodes = @('JP-SERVER')
$missingVmConfig = [pscustomobject]@{
    vmOptions      = [pscustomobject]@{ domainName = 'example.test'; domainNetBiosName = 'EXAMPLE' }
    parameters     = [pscustomobject]@{ ThisMachineName = '' }
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'JP-SERVER'; role = 'DomainMember'; operatingSystem = 'Server 2025'; locale = 'ja-JP'; localeAcquisition = 'MicrosoftMedia'; domain = 'example.test'; hidden = $false }
    )
}
$missingVmResult = Start-PhaseJobs -Phase 3 -deployConfig $missingVmConfig
Assert-Phase3Equal 0 $script:LocaleProbeCalls 'Missing localized VM is rejected before the locale guest probe'
Assert-Phase3Equal 0 $script:StartedJobs.Count 'Missing localized VM creates no job'
Assert-Phase3Equal 1 $missingVmResult.Failed 'Missing localized VM retains the existing Hyper-V failure result'
Assert-Phase3Equal $true $missingVmResult.Applicable 'Missing localized VM remains an applicable failed phase'
Assert-Phase3Equal $true ([bool]($script:LogLines -match 'Re-run from Phase 1')) 'Missing localized VM retains the Phase 1 remediation'

Reset-Phase3TestState
$script:ConfigurationData = [pscustomobject]@{
    AllNodes = @(
        [pscustomobject]@{ NodeName = '*'; Role = '' }
        [pscustomobject]@{ NodeName = 'TARGET'; Role = 'DomainMember' }
        [pscustomobject]@{ NodeName = 'OTHER'; Role = 'DomainMember' }
    )
}
$script:MissingHyperVNodes = @()
$script:LocaleIssueVMs = @('OTHER')
$targetedConfig = [pscustomobject]@{
    vmOptions      = [pscustomobject]@{ domainName = 'example.test'; domainNetBiosName = 'EXAMPLE' }
    parameters     = [pscustomobject]@{ ThisMachineName = '' }
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'TARGET'; role = 'DomainMember'; operatingSystem = 'Server 2025'; locale = 'ja-JP'; localeAcquisition = 'MicrosoftMedia'; domain = 'example.test'; hidden = $false }
        [pscustomobject]@{ vmName = 'OTHER'; role = 'DomainMember'; operatingSystem = 'Server 2025'; locale = 'ja-JP'; localeAcquisition = 'MicrosoftMedia'; domain = 'example.test'; hidden = $false }
    )
}
$targetedResult = Start-PhaseJobs -Phase 3 -deployConfig $targetedConfig -OnlyVMs @('TARGET')
Assert-Phase3Equal 'TARGET' ($script:LocaleProbeNames -join ',') 'Targeted redispatch probes only the requested VM locale prerequisite'
Assert-Phase3Equal 1 $script:StartedJobs.Count 'Unrelated locale issue does not block targeted redispatch'
Assert-Phase3Equal 'TARGET [DomainMember] ' $script:StartedJobs[0].Name 'Targeted redispatch creates only the requested VM job'
Assert-Phase3Equal $false ([bool]$targetedResult.PreflightFailed) 'Targeted redispatch is not failed by an unrelated locale issue'

Reset-Phase3TestState
$script:ConfigurationData = [pscustomobject]@{
    AllNodes = @(
        [pscustomobject]@{ NodeName = '*'; Role = '' }
        [pscustomobject]@{ NodeName = 'JP-SERVER'; Role = 'DomainMember' }
    )
}
$script:MissingHyperVNodes = @()
$script:LocaleIssueVMs = @('JP-SERVER')
$localeFailureResult = Start-PhaseJobs -Phase 3 -deployConfig $missingVmConfig
Assert-Phase3Equal 1 $script:LocaleProbeCalls 'Phase 3 probes an applicable media-backed locale prerequisite'
Assert-Phase3Equal 0 $script:StartedJobs.Count 'Locale prerequisite failure blocks all Phase 3 jobs'
Assert-Phase3Equal 1 $localeFailureResult.Failed 'Locale prerequisite failure reports one failed preflight item'
Assert-Phase3Equal $true ([bool]$localeFailureResult.PreflightFailed) 'Locale prerequisite failure returns PreflightFailed'
Assert-Phase3Equal $true ([bool]($script:LogLines -match 'Re-run from Phase 2')) 'Locale prerequisite failure identifies Phase 2 remediation'

if ($script:Failures -ne 0) { throw "$script:Failures Phase 3 locale preflight test(s) failed" }
Write-Host 'ALL PHASE 3 LOCALE PREFLIGHT TESTS PASSED' -ForegroundColor Green