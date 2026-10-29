<#
.SYNOPSIS
    Exercises the shipped feature resource and Phase 8 receipt consumer without servicing Windows.
#>
#requires -Version 5.1
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$resourcePath = Join-Path $RootPath 'DSC\TemplateHelpDSC\TemplateHelpDSC.psm1'
$functionsPath = Join-Path $RootPath 'DSC\phases\ScriptFunctions.ps1'
function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}
$tokens = $null
$parseErrors = $null
$resourceAst = [Management.Automation.Language.Parser]::ParseFile($resourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "Resource parse errors: $($parseErrors -join '; ')" }
$class = @($resourceAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.TypeDefinitionAst] -and $node.Name -eq 'InstallFeatureForSCCM'
        }, $true))
Assert-True ($class.Count -eq 1) 'Expected one feature resource class.'
. ([scriptblock]::Create($class[0].Extent.Text))
$functionsAst = [Management.Automation.Language.Parser]::ParseFile($functionsPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "Phase function parse errors: $($parseErrors -join '; ')" }
$prerequisite = $functionsAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-CMRoleTargetPrerequisiteState'
    }, $true)
$assignment = $prerequisite.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq 'guestProbe'
    }, $true)
$guestBlock = $assignment.Right.Find({
        param($node) $node -is [Management.Automation.Language.ScriptBlockExpressionAst]
    }, $true).ScriptBlock.GetScriptBlock()

$fixture = [pscustomobject]@{
    MarkerExists = $false; MarkerLines = @(); MarkerWrites = 0; MarkerRemovals = 0
    InitialState = 'Missing'; AfterInstallState = 'Installed'; InstallMode = 'Success'
    InstallAttempted = $false; FeatureQueries = 0; InstallCalls = 0
    FailMarkerWrite = $false; ClientOS = $false
}
function Reset-Fixture {
    $fixture.MarkerExists = $false
    $fixture.MarkerLines = @()
    $fixture.MarkerWrites = 0
    $fixture.MarkerRemovals = 0
    $fixture.InitialState = 'Missing'
    $fixture.AfterInstallState = 'Installed'
    $fixture.InstallMode = 'Success'
    $fixture.InstallAttempted = $false
    $fixture.FeatureQueries = 0
    $fixture.InstallCalls = 0
    $fixture.FailMarkerWrite = $false
    $fixture.ClientOS = $false
    $global:DSCMachineStatus = 0
}
function Write-Status { param([string] $Message) }
function Get-WmiObject {
    param([string] $Class, $ErrorAction)
    Assert-True ($Class -eq 'Win32_OperatingSystem') "Unexpected WMI query: $Class"
    $productType = if ($fixture.ClientOS) { 1 } else { 3 }
    [pscustomobject]@{ ProductType = $productType }
}
function Get-WindowsFeature {
    [CmdletBinding()]
    param([string[]] $Name)
    Assert-True ($PSBoundParameters.ErrorAction -eq 'Stop') 'Feature state query is not terminating.'
    $fixture.FeatureQueries++
    $state = if ($fixture.InstallAttempted) { $fixture.AfterInstallState } else { $fixture.InitialState }
    foreach ($feature in $Name) {
        $installState = 'Installed'
        if ($feature -ieq 'BITS-IIS-Ext') { $installState = $state }
        [pscustomobject]@{ Name = $feature; InstallState = $installState }
    }
}
function Install-WindowsFeature {
    [CmdletBinding()]
    param([string[]] $Name, [switch] $IncludeManagementTools)
    Assert-True ($PSBoundParameters.ErrorAction -eq 'Stop' -and $IncludeManagementTools) 'Required installation lost its terminating contract.'
    Assert-True ($Name.Count -eq 1 -and $Name[0] -ieq 'BITS-IIS-Ext') 'The resource reinstalled already-installed features.'
    $fixture.InstallCalls++
    $fixture.InstallAttempted = $true
    switch ($fixture.InstallMode) {
        'NonTerminatingError' { Write-Error 'Feature download failed: 0x80240438'; return }
        'NoResult' { return }
        'Failure' { return [pscustomobject]@{ Success = $false; ExitCode = 'Failed'; RestartNeeded = 'No' } }
        'Restart' { return [pscustomobject]@{ Success = $true; ExitCode = 'SuccessRestartRequired'; RestartNeeded = 'Yes' } }
        default { return [pscustomobject]@{ Success = $true; ExitCode = 'Success'; RestartNeeded = 'No' } }
    }
}
function dism.exe { $global:LASTEXITCODE = 0 }
function Start-Sleep { param([int] $Seconds) }
function Get-PendingRebootReasons { 'FixtureReboot' }
function Test-Path {
    param([string] $LiteralPath, [string] $Path, [string] $PathType, $ErrorAction)
    $value = if ($LiteralPath) { $LiteralPath } else { $Path }
    if ($value -like '*InstallFeatureStatus*.txt') { return $fixture.MarkerExists }
    if ($value -eq 'C:\staging') { return $true }
    if ($value -like '*applicationHost.config') { return $true }
    if ($value -like 'HKLM:\*') { return $false }
    throw "Unexpected path probe: $value"
}
function Get-Content {
    param([string] $LiteralPath, [string] $Path, [int] $TotalCount, [switch] $Raw, $ErrorAction)
    $value = if ($LiteralPath) { $LiteralPath } else { $Path }
    if ($value -like '*InstallFeatureStatus*.txt') {
        if (-not $fixture.MarkerExists) { throw 'Fixture marker is absent.' }
        return $fixture.MarkerLines | Select-Object -First $TotalCount
    }
    if ($value -like '*applicationHost.config') {
        return '<configuration><system.webServer><globalModules /></system.webServer></configuration>'
    }
    throw "Unexpected content read: $value"
}
function Get-ChildItem {
    param([string] $Path, [switch] $File, $ErrorAction)
    Assert-True ($Path -eq 'C:\staging\InstallFeatureStatus*.txt') "Unexpected directory enumeration: $Path"
    if ($fixture.MarkerExists) {
        [pscustomobject]@{ FullName = 'C:\staging\InstallFeatureStatusFixture8.txt'; LastWriteTimeUtc = [datetime]::UtcNow }
    }
}
function Set-Content {
    [CmdletBinding()]
    param(
        [string] $LiteralPath,
        [Parameter(ValueFromPipeline = $true)][string] $Value,
        [switch] $Force,
        [string] $Encoding
    )
    begin { $lines = [Collections.Generic.List[string]]::new() }
    process { $lines.Add($Value) }
    end {
        Assert-True ($LiteralPath -like 'C:\staging\InstallFeatureStatus*.txt' -and $PSBoundParameters.ErrorAction -eq 'Stop') 'Marker write lost its explicit path/error contract.'
        if ($fixture.FailMarkerWrite) { throw 'synthetic marker write failure' }
        $fixture.MarkerExists = $true
        $fixture.MarkerLines = $lines.ToArray()
        $fixture.MarkerWrites++
    }
}
function Remove-Item {
    [CmdletBinding()]
    param([string] $LiteralPath, [switch] $Force)
    Assert-True ($LiteralPath -like 'C:\staging\InstallFeatureStatus*.txt') "Unexpected deletion: $LiteralPath"
    $fixture.MarkerExists = $false
    $fixture.MarkerLines = @()
    $fixture.MarkerRemovals++
}
function New-Item { throw 'The fixture staging directory already exists.' }
function Get-Service {
    param([string] $Name, $ErrorAction)
    [pscustomobject]@{ Name = $Name; Status = 'Running' }
}

$resource = New-Object -TypeName InstallFeatureForSCCM
$resource.Name = 'Fixture'
$resource.Role = @('SiteSystem', 'Management point')
$signature = $resource.FeatureSignature($resource.GetRequiredFeatures())
$verified = $resource.ReceiptVerificationStamp()

Reset-Fixture
$fixture.MarkerExists = $true
$fixture.MarkerLines = @($signature)
Assert-True (-not $resource.Test() -and $fixture.FeatureQueries -eq 1) 'A legacy receipt concealed missing IIS BITS support.'
$requirements = [pscustomobject]@{
    RoleName = 'MP'; RequiredFeatures = @('BITS', 'BITS-IIS-Ext')
    CheckSiteServerAdmin = $false; ExpectedComputerName = $env:COMPUTERNAME
    ExpectedSiteServerAccount = 'Fixture$'; ExpectedFqdn = 'fixture.example'
}
$guest = & $guestBlock $requirements
Assert-True ($guest.MissingFeatures.Count -eq 2 -and ($guest.Warnings -join '; ') -match 'Unverified Phase 3') 'Phase 8 accepted an unverified legacy receipt.'

Reset-Fixture
$fixture.InitialState = 'Installed'
$fixture.MarkerExists = $true
$fixture.MarkerLines = @($signature)
Assert-True ($resource.Test() -and $fixture.FeatureQueries -eq 1 -and $fixture.MarkerLines[1] -eq $verified) 'Healthy legacy receipts were not independently verified and migrated.'
$fixture.FeatureQueries = 0
Assert-True ($resource.Test() -and $fixture.FeatureQueries -eq 0) 'Verified receipts lost their cheap fast path.'
$guest = & $guestBlock $requirements
Assert-True ($guest.MissingFeatures.Count -eq 0 -and $guest.Errors.Count -eq 0) 'Phase 8 rejected the resource-generated verified receipt.'
$fixture.MarkerLines = @('BITS', $verified)
$guest = & $guestBlock $requirements
Assert-True ($guest.MissingFeatures -contains 'BITS-IIS-Ext') 'A verified receipt for an incomplete feature set satisfied Phase 8.'

foreach ($mode in @('NonTerminatingError', 'Failure', 'NoResult')) {
    Reset-Fixture
    $fixture.InstallMode = $mode
    $fixture.MarkerExists = $true
    $fixture.MarkerLines = @($signature, $verified)
    $caught = $null
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $resource.Set()
    }
    catch { $caught = $_ }
    finally { $ErrorActionPreference = $savedPreference }
    Assert-True ([bool]$caught -and -not $fixture.MarkerExists -and $fixture.MarkerWrites -eq 0) "$mode left a successful completion receipt."
    Assert-True ($fixture.InstallCalls -eq 1 -and $fixture.MarkerRemovals -eq 1) "$mode did not invalidate the old receipt before installation."
    if ($mode -eq 'NonTerminatingError') {
        Assert-True ($caught.Exception.Message -match '0x80240438') 'Original feature download failure was lost.'
    }
}

Reset-Fixture
$fixture.AfterInstallState = 'Missing'
$caught = $null
try { $resource.Set() } catch { $caught = $_ }
Assert-True ($caught -and $caught.Exception.Message -match 'not Installed' -and -not $fixture.MarkerExists) 'Installer Success=True was trusted without checking actual installed state.'

Reset-Fixture
$resource.Set()
Assert-True ($fixture.FeatureQueries -eq 2 -and $fixture.MarkerLines.Count -eq 2 -and $fixture.MarkerLines[0] -eq $signature -and $fixture.MarkerLines[1] -eq $verified) 'Successful installation did not verify and persist the exact two-line receipt.'
Assert-True ($global:DSCMachineStatus -eq 0) 'A no-reboot installation requested a restart.'

foreach ($mode in @('Restart', 'AlreadyPending', 'PendingAfterInstall')) {
    Reset-Fixture
    if ($mode -eq 'Restart') { $fixture.InstallMode = 'Restart' }
    elseif ($mode -eq 'AlreadyPending') { $fixture.InitialState = 'InstallPending' }
    else { $fixture.AfterInstallState = 'InstallPending' }
    $fixture.MarkerExists = $true
    $fixture.MarkerLines = @($signature, $verified)
    $resource.Set()
    Assert-True ($global:DSCMachineStatus -eq 1 -and $verified -notin $fixture.MarkerLines) "$mode produced a verified receipt before the required reboot."
}

Reset-Fixture
$fixture.FailMarkerWrite = $true
$caught = $null
try { $resource.Set() } catch { $caught = $_ }
Assert-True ($caught -and $caught.Exception.Message -match 'synthetic marker write failure') 'Receipt write failure was swallowed.'

Reset-Fixture
$fixture.ClientOS = $true
$resource.Set()
Assert-True ($fixture.MarkerLines.Count -eq 1 -and $fixture.MarkerLines[0] -eq 'Finished' -and $resource.Test()) 'Client-OS one-time marker behavior changed.'
Write-Host "PASS -- verified Windows feature receipts, installer failure semantics, reboot handling, and actual Phase 8 receipt consumption (PowerShell $($PSVersionTable.PSVersion))."
