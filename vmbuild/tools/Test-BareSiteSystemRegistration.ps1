<#
.SYNOPSIS
    Verifies retained workflows reconcile bare site-system registration.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'deployConfig', Justification = 'Read by the extracted workflow and installer blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'ValidSiteCodes', Justification = 'Read by the extracted installer role-selection block.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'DomainFullName', Justification = 'Read by the extracted registration blocks.')]
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

function Assert-Equal {
    param($Expected, $Actual, [string] $Message)
    if ("$Expected" -ne "$Actual") {
        throw "$Message`nExpected: $Expected`nActual:   $Actual"
    }
}

function New-TestConfiguration {
    param([string] $InstallStatus = 'Completed')
    $steps = [ordered]@{}
    foreach ($name in @('InstallDP', 'InstallMP', 'InstallSUP', 'ConfigureMPReplica')) {
        $status = if ($name -eq 'InstallDP') { $InstallStatus } else { 'Completed' }
        $steps[$name] = [pscustomobject]@{
            Status = $status; StartTime = 'old-start'; EndTime = 'old-end'
        }
    }
    [pscustomobject]$steps
}

function Write-DscStatus {
    param([string] $Message, [switch] $Failure)
    if ($Failure) { throw $Message }
}
function Write-StatusLogEntry {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)] $Message)
    process {}
}

$asts = @{}
foreach ($name in @('ScriptWorkFlow', 'InstallDPMPClient')) {
    $path = Join-Path $RootPath "DSC\phases\$name.ps1"
    $tokens = $null
    $errors = $null
    $asts[$name] = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$path has parse errors: $($errors -join '; ')" }
}

$resetAssignments = @($asts.ScriptWorkFlow.FindAll({
    param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$newSiteSystemVMs'
}, $true))
$resetGates = @($asts.ScriptWorkFlow.FindAll({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
    $node.Clauses[0].Item1.Extent.Text -eq '$newSiteSystemVMs.Count -gt 0'
}, $true))
Assert-Equal 1 $resetAssignments.Count 'Expected one add-to-existing SiteSystem selection.'
Assert-Equal 1 $resetGates.Count 'Expected one add-to-existing SiteSystem reset gate.'
$resetScript = [scriptblock]::Create($resetAssignments[0].Extent.Text + "`n" + $resetGates[0].Extent.Text)

foreach ($roleFlag in @('Bare', 'installDP', 'installMP', 'installSUP', 'installRP', 'installSMSProv')) {
    foreach ($initialStatus in @('Completed', 'NotStart', 'Running', 'Error')) {
        $vm = [pscustomobject]@{
            vmName = 'PS1-SYSTEM'; role = 'SiteSystem'; siteCode = 'PS1'; useProxy = $false
            installDP = $false; installMP = $false; installSUP = $false
            installRP = $false; installSMSProv = $false; useDatabaseReplica = $false
        }
        if ($roleFlag -ne 'Bare') { $vm.$roleFlag = $true }
        $deployConfig = [pscustomobject]@{ virtualMachines = @($vm) }
        $Configuration = New-TestConfiguration -InstallStatus $initialStatus
        & $resetScript

        $expectedStatus = if ($initialStatus -eq 'Completed') { 'NotStart' } else { $initialStatus }
        $expectedStart = if ($initialStatus -eq 'Completed') { '' } else { 'old-start' }
        $expectedEnd = if ($initialStatus -eq 'Completed') { '' } else { 'old-end' }
        $expectedMP = if ($initialStatus -eq 'Completed') { 'NotStart' } else { 'Completed' }
        $expectedSUP = if ($roleFlag -in @('installSUP', 'installRP')) { 'NotStart' } else { 'Completed' }
        Assert-Equal $expectedStatus $Configuration.InstallDP.Status "$roleFlag/$initialStatus DP gate."
        Assert-Equal $expectedStart $Configuration.InstallDP.StartTime "$roleFlag/$initialStatus DP start time."
        Assert-Equal $expectedEnd $Configuration.InstallDP.EndTime "$roleFlag/$initialStatus DP end time."
        Assert-Equal $expectedMP $Configuration.InstallMP.Status "$roleFlag/$initialStatus MP gate."
        Assert-Equal $expectedSUP $Configuration.InstallSUP.Status "$roleFlag/$initialStatus SUP gate."
        Assert-Equal 'Completed' $Configuration.ConfigureMPReplica.Status "$roleFlag reset unrelated replica work."
    }
}

$deployConfig = [pscustomobject]@{
    virtualMachines = @([pscustomobject]@{ vmName = 'PS1-SITE'; role = 'Primary' })
}
$Configuration = New-TestConfiguration
& $resetScript
Assert-Equal 'Completed' $Configuration.InstallDP.Status 'A deployment without SiteSystems reopened role installation.'

$roleSelections = @($asts.InstallDPMPClient.FindAll({
    param($node)
    $node -is [Management.Automation.Language.ForEachStatementAst] -and
    $node.Condition.Extent.Text -eq '$deployConfig.virtualMachines | Where-Object { $_.role -eq "SiteSystem" }'
}, $true))
$bareLoops = @($asts.InstallDPMPClient.FindAll({
    param($node)
    $node -is [Management.Automation.Language.ForEachStatementAst] -and
    $node.Variable.Extent.Text -eq '$BSS' -and $node.Condition.Extent.Text -eq '$BareSiteSystems'
}, $true) | Sort-Object { $_.Extent.StartOffset })
Assert-Equal 1 $roleSelections.Count 'Expected one SiteSystem role selection.'
Assert-Equal 2 $bareLoops.Count 'Expected bare-site-system readiness and registration loops.'
$selectRoles = [scriptblock]::Create($roleSelections[0].Extent.Text)
$checkRegistration = [scriptblock]::Create($bareLoops[0].Extent.Text)
$registerSystems = [scriptblock]::Create($bareLoops[1].Extent.Text)

$script:RegisteredSystems = @{}
$script:Registrations = [Collections.Generic.List[string]]::new()
function Get-CMSiteSystemServer {
    param($SiteSystemServerName, $SiteCode)
    if ($script:RegisteredSystems.ContainsKey("$SiteCode`:$SiteSystemServerName")) {
        [pscustomobject]@{ SiteCode = $SiteCode }
    }
}
function New-CMSiteSystemServer {
    param($SiteSystemServerName, $SiteCode)
    $key = "$SiteCode`:$SiteSystemServerName"
    $script:RegisteredSystems[$key] = $true
    $script:Registrations.Add($key)
}

$deployConfig = [pscustomobject]@{
    virtualMachines = @(
        [pscustomobject]@{
            vmName = 'PS1-BARE'; role = 'SiteSystem'; siteCode = 'PS1'; useProxy = $false
            installDP = $false; installMP = $false; installSUP = $false
            installRP = $false; installSMSProv = $false
        },
        [pscustomobject]@{ vmName = 'S01-BARE'; role = 'SiteSystem'; siteCode = 'S01' },
        [pscustomobject]@{ vmName = 'PS2-BARE'; role = 'SiteSystem'; siteCode = 'PS2' }
    )
}
$Configuration = New-TestConfiguration
& $resetScript
Assert-Equal 'NotStart' $Configuration.InstallDP.Status 'A retained bare SiteSystem bypassed its installer.'
$SiteCode = 'PS1'
$ValidSiteCodes = @('PS1', 'S01')
$DomainFullName = 'lab.test'
$DPs = @()
$MPs = @()
$PullDPs = @()
$BareSiteSystems = @()
. $selectRoles
Assert-Equal 2 $BareSiteSystems.Count 'Bare registration did not isolate the owning site and its secondary.'
Assert-Equal 0 (@($DPs) + @($MPs) + @($PullDPs)).Count 'A bare SiteSystem requested automated DP/MP installation.'
$allInstalled = $true
. $checkRegistration
Assert-Equal $false $allInstalled 'Missing bare systems incorrectly passed the installer readiness gate.'
. $registerSystems
Assert-Equal 'PS1:PS1-BARE.lab.test,S01:S01-BARE.lab.test' `
    (($script:Registrations | Sort-Object) -join ',') 'Bare site-system registration targets.'

$allInstalled = $true
. $checkRegistration
Assert-Equal $true $allInstalled 'Registered bare systems did not pass the installer readiness gate.'
. $registerSystems
Assert-Equal 2 $script:Registrations.Count 'Existing bare systems were registered more than once.'

Write-Host 'PASS -- retained workflows reconcile bare site systems, preserve role gates, and register only missing owned systems.'
