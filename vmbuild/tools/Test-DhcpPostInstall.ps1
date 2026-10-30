#requires -Version 5.1
[CmdletBinding()]
param ()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $root
$sources = @{
    Prereqs = Join-Path $root 'common\Common.Prereqs.ps1'
    Common = Join-Path $root 'Common.ps1'
    NewLab = Join-Path $root 'New-Lab.ps1'
    HostTask = Join-Path $repoRoot 'configmgr-lab-vmhost\scripts\configureHostTask.ps1'
    HostSetup = Join-Path $repoRoot 'configmgr-lab-vmhost\scripts\configureHost.ps1'
}
$asts = @{}
foreach ($name in $sources.Keys) {
    $parseErrors = $null
    $asts[$name] = [Management.Automation.Language.Parser]::ParseFile($sources[$name], [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "$name has parse errors: $($parseErrors -join '; ')" }
}
foreach ($entry in @(
        @{ Source = 'Prereqs'; Function = 'Initialize-MemLabsDhcpServer' }
        @{ Source = 'Common'; Function = 'Start-DHCP' }
    )) {
    $functionName = $entry.Function
    $definition = $asts[$entry.Source].Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $true)
    if (-not $definition) { throw "$functionName was not found." }
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-RolePath {
    param([string]$Path)
    Assert-True ($Path -eq 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12') 'An unrelated registry key was accessed.'
}
function Reset-Scenario {
    param([string]$Name)
    $script:Scenario = $Name
    $script:KeyExists = $Name -ne 'MissingKey'
    $script:State = 1
    if ($Name -eq 'AlreadyComplete') { $script:State = 2 }
    $script:Events = [Collections.Generic.List[string]]::new()
    $script:Messages = [Collections.Generic.List[object]]::new()
    $script:Groups = 0
    $script:Restarts = 0
    $script:Starts = 0
    $script:Waits = 0
    $script:Writes = 0
    $script:Service = [pscustomobject]@{ Status = 'Running' }
    if ($Name -in @('StoppedService', 'StartFailure')) { $script:Service.Status = 'Stopped' }
    $script:Service | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value {
        param($Status, $Timeout)
        Assert-True ($Status -eq 'Running' -and $Timeout.TotalSeconds -eq 30) 'Service readiness lost its bounded Running-state check.'
        $script:Waits++
        if ($script:Scenario -eq 'WaitFailure') { throw 'Synthetic service readiness timeout' }
        $this.Status = 'Running'
    }
}
function Test-Path {
    [CmdletBinding()]
    param([string]$LiteralPath)
    Assert-RolePath $LiteralPath
    if ($script:Scenario -eq 'PathFailure') { throw 'Synthetic registry path access failure' }
    return $script:KeyExists
}
function Get-ItemProperty {
    [CmdletBinding()]
    param([string]$LiteralPath)
    Assert-RolePath $LiteralPath
    if ($script:Scenario -eq 'ReadFailure') { throw 'Synthetic registry read failure' }
    if ($script:Scenario -eq 'MissingValue' -and $script:Writes -eq 0) { return [pscustomobject]@{} }
    return [pscustomobject]@{ ConfigurationState = $script:State }
}
function Get-Service {
    [CmdletBinding()]
    param([string]$Name)
    Assert-True ($Name -eq 'DHCPServer') 'An unrelated service was queried.'
    if ($script:Scenario -eq 'MissingService') { throw 'Synthetic missing DHCP service' }
    return $script:Service
}
function Start-Service {
    [CmdletBinding()]
    param([string]$Name)
    Assert-True ($Name -eq 'DHCPServer') 'An unrelated service was started.'
    $script:Starts++
    if ($script:Scenario -eq 'StartFailure') { throw 'Synthetic DHCP start failure' }
    $script:Service.Status = 'Running'
}
function Get-DhcpServerSetting {
    [CmdletBinding()]
    param ()
    $script:Events.Add('Settings')
    if ($script:Scenario -eq 'SettingsFailure') { throw 'Synthetic DHCP settings failure' }
    if ($script:Scenario -eq 'EmptySettings') { return }
    if ($script:Scenario -eq 'UnknownAuthorization') { return [pscustomobject]@{ IsDomainJoined = $true } }
    return [pscustomobject]@{
        IsDomainJoined = $script:Scenario -in @('AuthorizedDomain', 'UnauthorizedDomain')
        IsAuthorized = $script:Scenario -eq 'AuthorizedDomain'
    }
}
function Add-DhcpServerSecurityGroup {
    [CmdletBinding()]
    param ()
    $script:Events.Add('Groups')
    $script:Groups++
    if ($script:Scenario -eq 'GroupFailure') { throw 'Synthetic security group creation failure' }
    [pscustomobject]@{ Created = $true }
}
function Restart-Service {
    [CmdletBinding()]
    param([string]$Name)
    Assert-True ($Name -eq 'DHCPServer') 'An unrelated service was restarted.'
    $script:Events.Add('Restart')
    $script:Restarts++
    if ($script:Scenario -eq 'RestartFailure') { throw 'Synthetic DHCP restart failure' }
}
function New-Item {
    [CmdletBinding()]
    param([string]$Path, [switch]$Force)
    Assert-RolePath $Path
    Assert-True $Force 'The missing DHCP role key was not created idempotently.'
    $script:KeyExists = $true
    [pscustomobject]@{ Name = $Path }
}
function New-ItemProperty {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Name, [string]$PropertyType, [int]$Value, [switch]$Force)
    Assert-RolePath $LiteralPath
    Assert-True ($script:KeyExists -and $Name -eq 'ConfigurationState' -and
        $PropertyType -eq 'DWord' -and $Value -eq 2 -and $Force) 'The Server Manager completion marker changed shape.'
    Assert-True ($script:Groups -eq 1 -and $script:Restarts -eq 1 -and $script:Waits -gt 0) `
        'The completion marker was written before successful DHCP initialization.'
    $script:Events.Add('Marker')
    $script:Writes++
    if ($script:Scenario -eq 'WriteFailure') { throw 'Synthetic registry write failure' }
    if ($script:Scenario -ne 'ReadbackMismatch') { $script:State = $Value }
    [pscustomobject]@{ ConfigurationState = $Value }
}
function Get-ItemPropertyValue {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Name)
    Assert-RolePath $LiteralPath
    Assert-True ($Name -eq 'ConfigurationState') 'An unrelated registry value was read.'
    if ($script:Scenario -eq 'ReadbackFailure') { throw 'Synthetic completion readback failure' }
    return $script:State
}
function Write-PrereqLog {
    param([string]$Message, [string]$Level = 'Info')
    $script:Messages.Add([pscustomobject]@{ Text = $Message; Level = $Level })
}

$successCases = @('Workgroup', 'MissingKey', 'MissingValue', 'StoppedService', 'AuthorizedDomain')
$failureCases = @('PathFailure', 'ReadFailure', 'MissingService', 'StartFailure', 'SettingsFailure',
    'EmptySettings', 'UnknownAuthorization', 'UnauthorizedDomain', 'GroupFailure', 'RestartFailure',
    'WaitFailure', 'WriteFailure', 'ReadbackMismatch', 'ReadbackFailure')
foreach ($scenario in @($successCases + $failureCases + 'AlreadyComplete')) {
    Reset-Scenario $scenario
    $failure = $null
    $result = @()
    try { $result = @(Initialize-MemLabsDhcpServer) }
    catch { $failure = $_.Exception.Message }
    $successLogs = @($script:Messages | Where-Object { $_.Level -eq 'Success' })
    if ($scenario -in $failureCases) {
        Assert-True ($null -ne $failure -and $successLogs.Count -eq 0) "$scenario was hidden or reported as successful."
        if ($scenario -notin @('WriteFailure', 'ReadbackMismatch', 'ReadbackFailure')) {
            Assert-True ($script:Writes -eq 0) "$scenario prematurely dismissed Server Manager's task."
        }
        if ($scenario -eq 'UnauthorizedDomain') {
            Assert-True ($failure -match 'must be authorized' -and $script:Groups -eq 0 -and $script:Restarts -eq 0) `
                'Unauthorized domain DHCP was mutated or its authorization requirement was hidden.'
        }
    }
    elseif ($scenario -eq 'AlreadyComplete') {
        Assert-True ($null -eq $failure -and $result.Count -eq 0 -and $script:Events.Count -eq 0 -and
            $script:Starts -eq 0 -and $script:Waits -eq 0) 'Completed hosts were unnecessarily changed.'
    }
    else {
        Assert-True ($null -eq $failure -and $result.Count -eq 0 -and $script:State -eq 2 -and
            $script:Groups -eq 1 -and $script:Restarts -eq 1 -and $script:Writes -eq 1 -and $successLogs.Count -eq 1) `
            "$scenario did not complete DHCP post-install configuration: $failure"
        Assert-True (($script:Events -join ',') -eq 'Settings,Groups,Restart,Marker') "$scenario changed the initialization order."
        $null = Initialize-MemLabsDhcpServer
        Assert-True ($script:Groups -eq 1 -and $script:Restarts -eq 1 -and $script:Writes -eq 1) `
            "$scenario repeated the one-time setup on a second invocation."
    }
}

& {
    $script:DhcpRestart = ${function:Restart-Service}
    function Get-Command {
        param($Name, $ErrorAction)
        Assert-True ($Name -eq 'Get-Service' -or
            ($Name -eq 'Install-WindowsFeature' -and $script:Scenario -like 'ModuleReinstall*')) `
            'Runtime DHCP unexpectedly tried to install features.'
        [pscustomobject]@{ Name = $Name }
    }
    function Import-Module {
        param($Name, [switch]$Force, [switch]$SkipEditionCheck, $ErrorAction)
        $expectedSkip = $PSVersionTable.PSEdition -eq 'Core'
        Assert-True ($Name -eq 'DhcpServer' -and $Force -and $ErrorAction -eq 'Stop' -and
            $PSBoundParameters.ContainsKey('SkipEditionCheck') -eq $expectedSkip -and $SkipEditionCheck.IsPresent -eq $expectedSkip) `
            'Runtime DHCP passed incompatible module import parameters.'
        $script:Imports++
        if ($script:Scenario -eq 'InvalidImportParameter') {
            throw [Management.Automation.ParameterBindingException]::new('Synthetic invalid import parameter')
        }
        if (($script:Imports -eq 1 -and $script:Scenario -in @('WmiRecovery', 'ModuleReinstall', 'ModuleReinstallFailure')) -or
            $script:Scenario -eq 'ModuleReinstallFailure') {
            throw 'Synthetic module import failure'
        }
    }
    function Get-Module {
        param($Name, [switch]$ListAvailable, $ErrorAction)
        Assert-True ($Name -eq 'DhcpServer' -and $ListAvailable) 'Runtime DHCP queried unrelated modules.'
        if ($script:Scenario -notlike 'ModuleReinstall*') { [pscustomobject]@{ Name = $Name } }
    }
    function Install-WindowsFeature {
        param($Name, [switch]$Confirm, $ErrorAction)
        Assert-True ($Name -eq 'RSAT-DHCP' -and $ErrorAction -eq 'SilentlyContinue') 'Runtime DHCP reinstalled an unrelated feature.'
        [pscustomobject]@{ Success = $true }
    }
    function Restart-Service {
        [CmdletBinding()]
        param($Name, [switch]$Force)
        if ($Name -eq 'winmgmt') {
            Assert-True ($script:Scenario -eq 'WmiRecovery' -and $Force) 'A non-WMI import error restarted WMI.'
            $script:WmiRestarts++
            return
        }
        & $script:DhcpRestart -Name $Name -ErrorAction Stop
    }
    function Repair-CimProxyTempPath { return $false }
    function Test-CimProxyStale { return $false }
    function Start-Sleep { $script:Sleeps++ }
    function Write-OrangePoint { param($Message) }
    function Write-GreenCheck { param($Message) }
    function Write-Log {
        param($Message, [switch]$Failure, [switch]$Warning)
        $script:Messages.Add([pscustomobject]@{ Text = $Message; Level = $(if ($Failure) { 'Failure' } else { 'Info' }) })
    }
    foreach ($scenario in @('Workgroup', 'AlreadyComplete', 'GroupFailure', 'WmiRecovery',
            'ModuleReinstall', 'ModuleReinstallFailure', 'InvalidImportParameter')) {
        Reset-Scenario $scenario
        $script:Imports = 0
        $script:WmiRestarts = 0
        $script:Sleeps = 0
        $result = @(Start-DHCP)
        $expectedSuccess = $scenario -notin @('GroupFailure', 'ModuleReinstallFailure', 'InvalidImportParameter')
        Assert-True ($result.Count -eq 1 -and $result[0] -is [bool] -and $result[0] -eq $expectedSuccess) `
            "$scenario changed Start-DHCP's Boolean result contract."
        if ($scenario -eq 'GroupFailure') {
            Assert-True (($script:Messages.Text -join ' ') -match 'post-install configuration failed.*Synthetic security group') `
                'Runtime DHCP did not report the actual post-install error.'
        }
        elseif ($scenario -eq 'ModuleReinstallFailure') {
            Assert-True ($script:Groups -eq 0 -and $script:Writes -eq 0 -and
                ($script:Messages.Text -join ' ') -match "still won't load after reinstalling") `
                'Failed imports after RSAT installation were incorrectly reported as successful.'
        }
        elseif ($scenario -eq 'InvalidImportParameter') {
            Assert-True ($script:WmiRestarts -eq 0 -and $script:Sleeps -eq 0 -and $script:Writes -eq 0 -and
                ($script:Messages.Text -join ' ') -match 'restarting WMI cannot fix this') `
                'An invalid module parameter was misclassified as a WMI failure.'
        }
        else { Assert-True ($script:State -eq 2) 'Runtime DHCP did not complete the post-install task.' }
        Assert-True ($script:WmiRestarts -eq [int]($scenario -eq 'WmiRecovery')) 'WMI recovery behavior changed.'
    }
}

$downloadStatements = @($asts.HostTask.EndBlock.Statements | Where-Object {
        $_.Extent.Text -match '^\$(prereqPath|prereqUrl)\s*=' -or
        $_.Extent.Text -match '^Start-BitsTransfer -Source \$prereqUrl\b'
    })
Assert-True ($downloadStatements.Count -eq 3) 'Host provisioning lost its shared-helper download.'
& {
    function Start-BitsTransfer {
        param($Source, $Destination, $Priority, $ErrorAction)
        Assert-True ($Priority -eq 'Foreground' -and $ErrorAction -eq 'Stop') 'Host helper download failures could be hidden.'
        $script:Download = [pscustomobject]@{ Source = $Source; Destination = $Destination }
    }
    foreach ($branch in @('main', 'develop')) {
        $ScriptUrl = "https://raw.githubusercontent.com/vinaypamnani-msft/memlabs/$branch/configmgr-lab-vmhost/scripts/configureHost.ps1"
        foreach ($statement in $downloadStatements) { . ([scriptblock]::Create($statement.Extent.Text)) }
        $expectedSource = $ScriptUrl -replace '/configmgr-lab-vmhost/scripts/configureHost\.ps1$', '/vmbuild/common/Common.Prereqs.ps1'
        Assert-True ($script:Download.Source -eq $expectedSource -and
            $script:Download.Destination -eq "$env:windir\temp\Common.Prereqs.ps1") 'Host provisioning downloaded helpers from a different branch or to the wrong location.'
    }
}
$setupStep = @($asts.HostSetup.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.TryStatementAst] -and
        $_.Body.Extent.Text -match '\bInitialize-MemLabsDhcpServer\b'
    })
Assert-True ($setupStep.Count -eq 1 -and
    $setupStep[0].Body.Extent.Text -match "Join-Path \`$PSScriptRoot 'Common.Prereqs.ps1'" -and
    $setupStep[0].CatchClauses[0].Body.Extent.Text -match 'Write-HostLog.*FAILED' -and
    $setupStep[0].CatchClauses[0].Body.Statements[-1] -is [Management.Automation.Language.ThrowStatementAst]) `
    'Post-reboot provisioning lost shared DHCP setup or its logged, fatal failure contract.'

$versionGate = $asts.NewLab.EndBlock.Statements[0]
Assert-True ($versionGate -is [Management.Automation.Language.IfStatementAst] -and
    $versionGate.Extent.Text -match '\$PSVersionTable.PSVersion -lt \[Version\]''7.4''' -and
    $versionGate.Extent.Text -match 'exit 1') 'New-Lab did not check its minimum runtime before host initialization.'
$legacyShell = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$legacyOutput = & $legacyShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $sources.NewLab
$legacyExit = $LASTEXITCODE
Assert-True ($legacyExit -eq 1 -and ($legacyOutput -join ' ') -match 'requires PowerShell 7.4' -and
    ($legacyOutput -join ' ') -notmatch 'Loading Common.ps1|New-Lab starting|Start-DHCP') `
    'Windows PowerShell 5.1 was not rejected cleanly before host preparation.'

$launcherText = [IO.File]::ReadAllText((Join-Path $root 'VMBuild.cmd'))
Assert-True ($launcherText -notmatch '(?im)^\s*(GOTO PS5|:PS5)\s*$') 'The launcher still falls back to the unsupported legacy runtime.'
$checkStart = $launcherText.IndexOf('SET PS7=')
$checkEnd = $launcherText.IndexOf(':PS7', $checkStart)
Assert-True ($checkStart -ge 0 -and $checkEnd -gt $checkStart) 'The launcher runtime check was not found.'
$launcherCheck = $launcherText.Substring($checkStart, $checkEnd - $checkStart)
$launcherFixture = Join-Path ([IO.Path]::GetTempPath()) "MemLabs-DhcpLauncher-$([guid]::NewGuid().ToString('N')).cmd"
try {
    [IO.File]::WriteAllText($launcherFixture, "@ECHO OFF`r`nPUSHD .`r`nSET `"ProgramFiles=%~f0-missing`"`r`n$launcherCheck`r`nEXIT /B 0`r`n", [Text.Encoding]::ASCII)
    $launcherOutput = & $env:ComSpec /d /c ('"{0}"' -f $launcherFixture)
    $launcherExit = $LASTEXITCODE
    Assert-True ($launcherExit -eq 1 -and ($launcherOutput -join ' ') -match 'PowerShell 7.4 or later is required') `
        "The launcher did not stop when PowerShell 7 was missing. Exit: $launcherExit; output: $($launcherOutput -join ' ')"
}
finally {
    [IO.File]::Delete($launcherFixture)
}

Write-Host "PASS -- DHCP post-install: $($successCases.Count) success cases, $($failureCases.Count) failure cases, idempotency, both import paths, host provisioning, and early legacy-runtime rejection."
