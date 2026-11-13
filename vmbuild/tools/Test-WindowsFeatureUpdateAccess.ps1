<#
.SYNOPSIS
    Exercises scoped feature-payload access and exact rollback without changing Windows.
#>
#requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.ServiceProcess
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
$modulePath = Join-Path $RootPath 'DSC\TemplateHelpDSC\TemplateHelpDSC.psm1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "Resource parse errors: $($parseErrors -join '; ')" }
$definition = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Install-MemLabsRequiredWindowsFeature'
        }, $true))
Assert-True ($definition.Count -eq 1) 'Expected one scoped feature installer.'
. ([scriptblock]::Create($definition[0].Extent.Text))

$wuRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$policyNames = @('NoAutoUpdate', 'DoNotConnectToWindowsUpdateInternetLocations', 'DisableWindowsUpdateAccess', 'UseWUServer')
$featureWindowFixture = [pscustomobject]@{
    Values = @{}; OriginalValues = @{}; Keys = @{}; Mode = ''
    Startup = 4; OriginalStartup = 4; Status = 'Stopped'; OriginalStatus = 'Stopped'
    Calls = 0; Mutations = [Collections.Generic.List[string]]::new()
    Messages = [Collections.Generic.List[string]]::new(); Attempted = $false
}
function Reset-Fixture {
    param([string]$Mode = 'Success', [int]$Startup = 4, [string]$Status = 'Stopped', [switch]$Absent)
    $featureWindowFixture.Values = @{}
    $featureWindowFixture.Keys = @{}
    $featureWindowFixture.Mode = $Mode
    $featureWindowFixture.Startup = $Startup
    $featureWindowFixture.OriginalStartup = $Startup
    $featureWindowFixture.Status = $Status
    $featureWindowFixture.OriginalStatus = $Status
    $featureWindowFixture.Calls = 0
    $featureWindowFixture.Attempted = $false
    $featureWindowFixture.Mutations.Clear()
    $featureWindowFixture.Messages.Clear()
    if (-not $Absent) {
        foreach ($name in $policyNames) {
            $path = if ($name -in @('NoAutoUpdate', 'UseWUServer')) { "$wuRoot\AU" } else { $wuRoot }
            $featureWindowFixture.Keys[$path] = $true
            $featureWindowFixture.Values["$path\$name"] = [pscustomobject]@{ Kind = 'DWord'; Value = 1 }
        }
    }
    $featureWindowFixture.Values["$wuRoot\WUServer"] = [pscustomobject]@{ Kind = 'String'; Value = 'https://sup.example:8531' }
    $featureWindowFixture.Values["$wuRoot\WUStatusServer"] = [pscustomobject]@{ Kind = 'String'; Value = 'https://sup.example:8531' }
    $featureWindowFixture.Keys[$wuRoot] = $true
    $featureWindowFixture.OriginalValues = @{}
    foreach ($entry in $featureWindowFixture.Values.GetEnumerator()) {
        $featureWindowFixture.OriginalValues[$entry.Key] = [pscustomobject]@{ Kind = $entry.Value.Kind; Value = $entry.Value.Value }
    }
}
function Write-Status { param([string]$Status); $featureWindowFixture.Messages.Add($Status) }
function Test-Path {
    param([string]$LiteralPath, $ErrorAction)
    return $featureWindowFixture.Keys.ContainsKey($LiteralPath)
}
function Get-Item {
    param([string]$LiteralPath, $ErrorAction)
    if ($featureWindowFixture.Mode -eq 'SnapshotReadFailure') { throw 'synthetic snapshot read failure' }
    $key = [pscustomobject]@{ FixturePath = $LiteralPath }
    $key | Add-Member ScriptMethod GetValueNames {
        @($featureWindowFixture.Values.Keys | Where-Object { (Split-Path -Parent $_) -eq $this.FixturePath } |
            ForEach-Object { Split-Path -Leaf $_ })
    }.GetNewClosure()
    $key | Add-Member ScriptMethod GetValueKind {
        param($Name)
        $featureWindowFixture.Values["$($this.FixturePath)\$Name"].Kind
    }.GetNewClosure()
    $key | Add-Member ScriptMethod GetValue {
        param($Name, $Default, $Options)
        if ($Options -ne [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) { throw 'Policy snapshot expanded registry data.' }
        $featureWindowFixture.Values["$($this.FixturePath)\$Name"].Value
    }.GetNewClosure()
    $key | Add-Member ScriptMethod Dispose { }
    return $key
}
function Get-ItemProperty {
    param([string]$LiteralPath, [string]$Name, $ErrorAction)
    Assert-True ($LiteralPath -eq 'HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv' -and $Name -eq 'Start') 'Unexpected service registry query.'
    [pscustomobject]@{ Start = $featureWindowFixture.Startup }
}
function New-Item {
    param([string]$Path, [switch]$Force, $ErrorAction)
    Assert-True ($Path -in @($wuRoot, "$wuRoot\AU")) 'An unrelated registry key was created.'
    $featureWindowFixture.Keys[$Path] = $true
}
function New-ItemProperty {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Name, [string]$PropertyType, $Value, [switch]$Force)
    Assert-True ($Name -in $policyNames -and $PropertyType -eq 'DWord' -and $PSBoundParameters.ErrorAction -eq 'Stop') 'Unexpected or nonterminating policy change.'
    if ($featureWindowFixture.Mode -eq 'PartialPolicyWrite' -and $Name -eq 'DoNotConnectToWindowsUpdateInternetLocations' -and $Value -eq 0) {
        throw 'synthetic policy apply failure'
    }
    if ($featureWindowFixture.Mode -in @('RestorePolicyFailure', 'InstallAndRestoreFailure') -and
        $featureWindowFixture.Attempted -and $Name -eq 'DoNotConnectToWindowsUpdateInternetLocations' -and $Value -eq 1) {
        throw 'synthetic policy restore failure'
    }
    $featureWindowFixture.Mutations.Add("$Name=$Value")
    if ($featureWindowFixture.Mode -eq 'PolicyReapplied' -and $Name -eq 'DoNotConnectToWindowsUpdateInternetLocations' -and $Value -eq 0) {
        $Value = 1
    }
    $featureWindowFixture.Values["$LiteralPath\$Name"] = [pscustomobject]@{ Kind = $PropertyType; Value = $Value }
}
function Remove-ItemProperty {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Name, [switch]$Force)
    Assert-True ($Name -in $policyNames -and $PSBoundParameters.ErrorAction -eq 'Stop') 'An unrelated policy was removed.'
    $featureWindowFixture.Values.Remove("$LiteralPath\$Name")
}
function Get-Service {
    param([string]$Name, $ErrorAction)
    Assert-True ($Name -eq 'wuauserv') 'Feature installation touched a service other than Windows Update.'
    $service = [pscustomobject]@{ Status = $featureWindowFixture.Status }
    $service | Add-Member ScriptMethod Refresh { $this.Status = $featureWindowFixture.Status }.GetNewClosure()
    $service | Add-Member ScriptMethod Stop {
        $featureWindowFixture.Status = 'Stopped'
        $this.Status = 'Stopped'
    }.GetNewClosure()
    $service | Add-Member ScriptMethod Start {
        if ($featureWindowFixture.Startup -eq 4) { throw 'Cannot start a disabled service.' }
        $featureWindowFixture.Status = 'Running'
        if ($featureWindowFixture.Mode -eq 'StartTimeout' -and -not $featureWindowFixture.Attempted) {
            $featureWindowFixture.Status = 'StartPending'
        }
        $this.Status = $featureWindowFixture.Status
    }.GetNewClosure()
    $service | Add-Member ScriptMethod WaitForStatus {
        param($Status, $Timeout)
        if ($Timeout -ne [TimeSpan]::FromSeconds(30)) { throw 'A service wait is not bounded to 30 seconds.' }
        if ("$($this.Status)" -ne "$Status") { throw 'synthetic service start timeout' }
    }.GetNewClosure()
    return $service
}
function Set-Service {
    [CmdletBinding()]
    param([string]$Name, [string]$StartupType)
    Assert-True ($Name -eq 'wuauserv' -and $PSBoundParameters.ErrorAction -eq 'Stop') 'Unexpected service startup change.'
    if ($featureWindowFixture.Mode -eq 'RestoreServiceFailure' -and $StartupType -eq 'Disabled' -and $featureWindowFixture.Attempted) {
        throw 'synthetic service restore failure'
    }
    $featureWindowFixture.Startup = if ($StartupType -eq 'Manual') { 3 } elseif ($StartupType -eq 'Disabled') { 4 } else { throw "Unexpected startup: $StartupType" }
}
function Install-WindowsFeature {
    [CmdletBinding()]
    param([string[]]$Name, [switch]$IncludeManagementTools)
    Assert-True ($Name.Count -eq 1 -and $Name[0] -eq 'BITS-IIS-Ext' -and $IncludeManagementTools -and $PSBoundParameters.ErrorAction -eq 'Stop') 'Feature installation scope or error semantics changed.'
    Assert-True ($featureWindowFixture.Status -eq 'Running' -and $featureWindowFixture.Startup -ne 4) 'Feature payload access did not enable its service.'
    foreach ($policyName in $policyNames) {
        $path = if ($policyName -in @('NoAutoUpdate', 'UseWUServer')) { "$wuRoot\AU" } else { $wuRoot }
        $expected = if ($policyName -eq 'NoAutoUpdate') { 1 } else { 0 }
        Assert-True ($featureWindowFixture.Values["$path\$policyName"].Value -eq $expected) "Incorrect temporary policy: $policyName"
    }
    $featureWindowFixture.Calls++
    $featureWindowFixture.Attempted = $true
    if ($featureWindowFixture.Mode -in @('InstallFailure', 'InstallAndRestoreFailure')) { Write-Error 'synthetic feature source failure 0x80240438'; return }
    [pscustomobject]@{
        Success = $featureWindowFixture.Mode -ne 'FalseResult'
        RestartNeeded = if ($featureWindowFixture.Mode -eq 'Reboot') { 'Yes' } else { 'No' }
    }
}
function Assert-Restored {
    Assert-True ($featureWindowFixture.Startup -eq $featureWindowFixture.OriginalStartup -and $featureWindowFixture.Status -eq $featureWindowFixture.OriginalStatus) 'Original service start mode/state was not restored.'
    Assert-True ($featureWindowFixture.Values.Count -eq $featureWindowFixture.OriginalValues.Count) 'An originally absent update value was left behind.'
    foreach ($entry in $featureWindowFixture.OriginalValues.GetEnumerator()) {
        $actual = $featureWindowFixture.Values[$entry.Key]
        Assert-True ($actual.Kind -eq $entry.Value.Kind -and $actual.Value -eq $entry.Value.Value) "Original policy not restored: $($entry.Key)"
    }
}

foreach ($scenario in @(
        @{ Mode = 'Success'; Startup = 4; Status = 'Stopped' },
        @{ Mode = 'Success'; Startup = 2; Status = 'Running' },
        @{ Mode = 'Success'; Startup = 4; Status = 'Running' },
        @{ Mode = 'Reboot'; Startup = 3; Status = 'Stopped' },
        @{ Mode = 'FalseResult'; Startup = 4; Status = 'Stopped' }
    )) {
    Reset-Fixture @scenario
    $result = Install-MemLabsRequiredWindowsFeature -Name BITS-IIS-Ext
    Assert-Restored
    Assert-True ($featureWindowFixture.Calls -eq 1 -and $result.Success -eq ($scenario.Mode -ne 'FalseResult')) 'Installer result or call count changed.'
    if ($scenario.Mode -eq 'Reboot') { Assert-True ($result.RestartNeeded -eq 'Yes') 'Reboot-needed result was hidden.' }
}
Reset-Fixture -Startup 3 -Absent
$null = Install-MemLabsRequiredWindowsFeature -Name BITS-IIS-Ext
Assert-Restored
Reset-Fixture -Startup 2 -Status Running
foreach ($policyName in $policyNames) {
    $path = if ($policyName -in @('NoAutoUpdate', 'UseWUServer')) { "$wuRoot\AU" } else { $wuRoot }
    $featureWindowFixture.Values["$path\$policyName"].Value = 0
    $featureWindowFixture.OriginalValues["$path\$policyName"].Value = 0
}
$null = Install-MemLabsRequiredWindowsFeature -Name BITS-IIS-Ext
Assert-Restored

foreach ($mode in @('InstallFailure', 'PartialPolicyWrite', 'PolicyReapplied', 'StartTimeout')) {
    Reset-Fixture -Mode $mode
    $caught = $null
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $null = Install-MemLabsRequiredWindowsFeature -Name BITS-IIS-Ext
    }
    catch { $caught = $_ }
    finally { $ErrorActionPreference = $savedPreference }
    Assert-True ([bool]$caught) "$mode was converted to success."
    Assert-Restored
    if ($mode -eq 'InstallFailure') {
        Assert-True ($caught.Exception.Message -match '0x80240438') 'Original feature download error was lost.'
    }
    else { Assert-True ($featureWindowFixture.Calls -eq 0) "$mode still attempted installation." }
}
foreach ($mode in @('RestorePolicyFailure', 'RestoreServiceFailure', 'InstallAndRestoreFailure')) {
    Reset-Fixture -Mode $mode
    $featureWindowFixture.Values["$wuRoot\AU\NoAutoUpdate"].Value = 0
    $featureWindowFixture.OriginalValues["$wuRoot\AU\NoAutoUpdate"].Value = 0
    $caught = $null
    try { $null = Install-MemLabsRequiredWindowsFeature -Name BITS-IIS-Ext } catch { $caught = $_ }
    Assert-True ($caught -and $caught.Exception.Message -match 'settings restoration failed' -and
        $featureWindowFixture.Values["$wuRoot\AU\NoAutoUpdate"].Value -eq 1) "$mode hid a restoration failure or removed automatic-update protection."
    if ($mode -eq 'InstallAndRestoreFailure') {
        Assert-True ($caught.Exception.Message -match '0x80240438' -and $caught.Exception.Message -match 'synthetic policy restore failure') 'Cleanup failure replaced the installation error.'
    }
}
Reset-Fixture
$featureWindowFixture.Values["$wuRoot\DisableWindowsUpdateAccess"] = [pscustomobject]@{ Kind = 'String'; Value = 'unexpected' }
$caught = $null
try { $null = Install-MemLabsRequiredWindowsFeature -Name BITS-IIS-Ext } catch { $caught = $_ }
Assert-True ($caught -and $featureWindowFixture.Mutations.Count -eq 0 -and $featureWindowFixture.Calls -eq 0) 'Unexpected original policy types were overwritten.'
Reset-Fixture -Status StopPending
$caught = $null
try { $null = Install-MemLabsRequiredWindowsFeature -Name BITS-IIS-Ext } catch { $caught = $_ }
Assert-True ($caught -and $featureWindowFixture.Mutations.Count -eq 0 -and $featureWindowFixture.Calls -eq 0) 'A transient service state was mutated without a stable original snapshot.'
Reset-Fixture -Mode SnapshotReadFailure
$caught = $null
try { $null = Install-MemLabsRequiredWindowsFeature -Name BITS-IIS-Ext } catch { $caught = $_ }
Assert-True ($caught -and $caught.Exception.Message -match 'synthetic snapshot read failure' -and
    $featureWindowFixture.Mutations.Count -eq 0 -and $featureWindowFixture.Calls -eq 0) 'Unreadable original policy was changed or allowed installation.'

$commonTokens = $null
$commonErrors = $null
$commonAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RootPath 'common\Common.ScriptBlocks.ps1'), [ref]$commonTokens, [ref]$commonErrors)
if ($commonErrors.Count) { throw "Host parse errors: $($commonErrors -join '; ')" }
$collector = $commonAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Save-CMSetupLogsFromVm'
    }, $true)
$diagnosticLoops = @($collector.FindAll({
            param($node)
            $node -is [Management.Automation.Language.ForEachStatementAst] -and
            (($node.Variable.VariablePath.UserPath -eq 'policy' -and $node.Body.Extent.Text.Contains('$prereq.WindowsUpdate.Policies')) -or
                ($node.Variable.VariablePath.UserPath -eq 'serviceName' -and $node.Body.Extent.Text.Contains('$prereq.WindowsUpdate.Services')))
        }, $true))
Assert-True ($diagnosticLoops.Count -eq 2) 'Expected the policy and service evidence loops.'
& {
    Reset-Fixture
    $featureWindowFixture.Values["$wuRoot\UnrelatedSecret"] = [pscustomobject]@{ Kind = 'String'; Value = 'MUST-NOT-BE-EXPORTED' }
    $prereq = [ordered]@{ WindowsUpdate = [ordered]@{ Policies = @(); Services = @() }; Errors = @() }
    function Get-Service {
        param([string]$Name, $ErrorAction)
        [pscustomobject]@{ Name = $Name; Status = 'Stop Pending'; StartType = 'Disabled' }
    }
    foreach ($loop in $diagnosticLoops) { . ([scriptblock]::Create($loop.Extent.Text)) }
    Assert-True ($prereq.WindowsUpdate.Policies.Count -eq 6 -and $prereq.WindowsUpdate.Services.Count -eq 2 -and $prereq.Errors.Count -eq 0) 'Update-source diagnostics omitted expected policy/service state.'
    Assert-True ($prereq.WindowsUpdate.Services[0].Status -eq 'Stop Pending') 'Multiword Windows Update service status was truncated.'
    Assert-True (($prereq | ConvertTo-Json -Depth 6) -notmatch 'MUST-NOT-BE-EXPORTED') 'Update policy diagnostics exported values outside the allowlist.'
}
$sentinel = @($commonAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -eq '$currentStatusTrimmed.Contains("JOBFAILURE: ")'
        }, $true))
Assert-True ($sentinel.Count -eq 1) 'The host terminal-status handler is missing or ambiguous.'
$hostFixture = [pscustomobject]@{ Failed = $false }
function Write-Log {
    param($Text, [switch]$Failure, [switch]$OutputStream)
    if ($Failure -and $Text -match '0x80240438') { $hostFixture.Failed = $true }
}
$handlerText = $sentinel[0].Extent.Text.Replace('$using:Phase', '$Phase')
$handler = [scriptblock]::Create(@'
param($currentStatusTrimmed)
$Phase = 3
$currentItem = [pscustomobject]@{ vmName = 'FIXTURE'; role = 'SiteSystem' }
foreach ($iteration in 1) {
'@ + [Environment]::NewLine + $handlerText + @'

    throw 'The host would enter recovery instead of stopping on the terminal feature error.'
}
'@)
& $handler 'InstallFeatureForSCCM: JOBFAILURE: Required Windows feature installation failed: 0x80240438'
Assert-True $hostFixture.Failed 'The real host handler did not surface the original terminal feature error.'
Write-Host "PASS -- scoped feature payload access, exact policy/service rollback, partial/combined failure handling, and host fail-fast routing (PowerShell $($PSVersionTable.PSVersion))."
