#requires -Version 5.1
<#
.SYNOPSIS
    Verifies unchanged connections and resource edits do not rewrite RDG or restart RDCMan.
.DESCRIPTION
    Uses the normal MemLabs rdcman.dll with synthetic credentials and isolated files.
    All application and VM operations are mocked; no real client or VM is changed.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'rdcmanexe', Justification = 'Read dynamically by the source-loaded RDCMan exporter.')]
[CmdletBinding()]
param([string]$RootPath, [string]$RdcManDllPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
if (-not $RdcManDllPath) { $RdcManDllPath = Join-Path $RootPath 'azureFiles\support\rdcman.dll' }
Import-Module -Name $RdcManDllPath -ErrorAction Stop
$script:Assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}

. (Join-Path $RootPath 'common\Common.RdcMan.ps1')
$script:RealSettingsWriter = ${function:Save-RdcManSettingsFile}
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $RootPath 'common\Common.mRemoteNG.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Common.mRemoteNG.ps1 parse errors: $($errors -join '; ')" }
$hierarchy = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-MECMSiteHierarchy'
    }, $true)
if (-not $hierarchy) { throw 'Get-MECMSiteHierarchy was not found.' }
. ([scriptblock]::Create($hierarchy.Extent.Text))

$script:State = @{ Running = $false; Stops = 0; StopCalls = 0; Starts = 0; Logs = [Collections.Generic.List[string]]::new() }
$script:Settings = [pscustomobject](Get-RDCSettingsDefaults)
$script:FixturePassword = 'synthetic-rdcman-no-op'
$script:UseRealSettings = $false
function Get-RDCSettings { $script:Settings }
function Get-RDCManPassword {
    param([string]$rdcmanpath)
    [RdcMan.Encryption]::EncryptString($script:FixturePassword, (New-Object RdcMan.EncryptionSettings))
}
function Get-RDCManCmVersionForVM { param($VM, $Config, $DomainDefaults) $null }
function Install-RDCman {}
function Invoke-VMNetworkBulkWarmup {}
function Test-RDCManCertTrustSupported { $true }
function Update-VmRdpCertNote { param($VmName, $VmDomainName) $null }
function Save-VmRdpCertNote { param($VmName, $Sha256) $true }
function Test-VmIsLinux { param($Vm) $Vm.Role -like 'Linux*' }
function Get-VMNetworkAdapter {
    [CmdletBinding()]
    param([string]$VMName)
    [pscustomobject]@{ IPAddresses = @('192.0.2.44') }
}
function Get-Process {
    [CmdletBinding()]
    param([string]$Name)
    if ($script:State.Running) { [pscustomobject]@{ Id = 101; Path = $script:ExePath } }
}
function Stop-RDCMan {
    $script:State.StopCalls++
    if ($script:State.Running) {
        $script:State.Stops++
        $script:State.Running = $false
        return $true
    }
    return $false
}
function Start-Process {
    [CmdletBinding()]
    param([string]$FilePath, $ArgumentList, $WindowStyle, $WorkingDirectory, [switch]$PassThru)
    if ($FilePath -ne $script:ExePath) { throw 'Wrong RDCMan executable selected.' }
    $script:State.Starts++
    $script:State.Running = $true
    [pscustomobject]@{ Id = 102 }
}
function Save-RdcManSettingsFile {
    param([string]$rdcmanfile)
    if ($script:UseRealSettings) { return & $script:RealSettingsWriter -rdcmanfile $rdcmanfile }
    return $false
}
function Start-Sleep { param([int]$Seconds) }
function Set-RdcManMin {}
function Write-GreenCheck { param([string]$Message, $ForegroundColor) }
function Write-RedX { param([string]$Message) throw $Message }
function Write-Log {
    [CmdletBinding()]
    param([string]$Message, [switch]$LogOnly, [switch]$Activity, [switch]$Failure, [switch]$Success, [switch]$Warning)
    $script:State.Logs.Add($Message)
}

function Invoke-Refresh {
    param([switch]$OverWrite, [switch]$WhatIf, [switch]$UseIP)
    $script:State.Stops = 0
    $script:State.StopCalls = 0
    $script:State.Starts = 0
    New-RDCManFileFromHyperV -rdcmanfile $script:Target -VmInventory $script:Inventory `
        -OverWrite:$OverWrite -WhatIf:$WhatIf -UseIP:$UseIP -NoActivity | Out-Null
}
function Assert-NoOp {
    param([string]$Message)
    $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:Target))
    $timestamp = [IO.File]::GetLastWriteTimeUtc($script:Target)
    Invoke-Refresh
    Assert-True ($script:State.StopCalls -eq 0 -and $script:State.Starts -eq 0) "$Message stopped or restarted RDCMan."
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($script:Target)) -ceq $before -and
        [IO.File]::GetLastWriteTimeUtc($script:Target) -eq $timestamp) "$Message rewrote unchanged connection data."
}
function Assert-Refreshed {
    param([string]$Message)
    Assert-True ($script:State.Stops -eq 1 -and $script:State.Starts -eq 1) "$Message did not refresh running RDCMan exactly once."
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-rdcman-no-op-' + [guid]::NewGuid().ToString('N'))
$previousRdcPath = $Global:newrdcmanpath
$previousLocalAppData = $env:LOCALAPPDATA
try {
    $null = New-Item -ItemType Directory -Path $fixtureRoot
    $env:LOCALAPPDATA = Join-Path $fixtureRoot 'localappdata'
    $script:ExePath = Join-Path $fixtureRoot 'RDCMan.exe'
    [IO.File]::WriteAllText($script:ExePath, 'Synthetic executable; never launched.')
    $Global:newrdcmanpath = $fixtureRoot
    $rdcmanexe = 'RDCMan.exe'
    $script:Target = Join-Path $fixtureRoot 'memlabs.rdg'
    $dc = [pscustomobject]@{
        vmName = 'LAB-DC'; Role = 'DC'; Domain = 'lab.test'; AdminName = 'admin'; network = '192.0.2.0'
        deployedOS = 'Server 2025'; LastKnownIP = '192.0.2.10'; state = 'Off'
    }
    $client = [pscustomobject]@{
        vmName = 'LAB-W11'; Role = 'DomainMember'; Domain = 'lab.test'; network = '192.0.2.0'
        deployedOS = 'Windows 11 latest'; LastKnownIP = '192.0.2.11'; state = 'Off'
        Memory = '4GB'; DynamicMinRam = '1GB'; memoryStartupGB = 4; memoryGB = 0; diskUsedGB = 12
    }
    $primary = [pscustomobject]@{
        vmName = 'LAB-PRI'; Role = 'Primary'; Domain = 'lab.test'; AdminName = 'admin'; network = '192.0.2.0'
        deployedOS = 'Server 2025'; LastKnownIP = '192.0.2.12'; SiteCode = 'P01'; state = 'Off'
    }
    $linux = [pscustomobject]@{
        vmName = 'LAB-LINUX'; Role = 'LinuxClient'; Domain = 'lab.test'; AdminName = 'admin'; network = '192.0.2.0'
        deployedOS = 'Ubuntu Desktop 24.04 LTS'; LastKnownIP = '192.0.2.44'; state = 'Off'; enableRDP = $true
    }
    $script:Inventory = @($dc, $client, $primary, $linux)
    Invoke-Refresh -OverWrite
    Assert-True ([IO.File]::Exists($script:Target)) 'Initial RDG generation failed.'
    $script:State.Running = $true
    1..3 | ForEach-Object { Assert-NoOp "Unchanged default-grouping pass $_" }

    $client.DynamicMinRam = '4GB'
    $client.memoryGB = 4
    $client.diskUsedGB = 13
    $client.state = 'Running'
    Assert-NoOp 'Dynamic-memory off and changed resource/state metadata'

    foreach ($key in @($script:Settings.PSObject.Properties.Name | Where-Object { $_ -like 'Show*' })) {
        $script:Settings.$key = $false
    }
    Invoke-Refresh
    Assert-Refreshed 'Removing display-name decorations'
    [xml]$clientSaved = [IO.File]::ReadAllText($script:Target)
    $omittedNames = 0
    foreach ($properties in @($clientSaved.SelectNodes('//server/properties'))) {
        $displayNode = $properties.SelectSingleNode('displayName')
        if ($displayNode.InnerText -ceq $properties.name) {
            [void]$properties.RemoveChild($displayNode)
            $omittedNames++
        }
        $normal = $clientSaved.CreateElement('connectionType')
        $normal.InnerText = 'Normal'
        [void]$properties.AppendChild($normal)
        foreach ($child in @($properties.SelectNodes('*') | Sort-Object LocalName -Descending)) {
            [void]$properties.AppendChild($child)
        }
    }
    foreach ($credentials in @($clientSaved.SelectNodes('//logonCredentials'))) {
        foreach ($child in @($credentials.SelectNodes('*') | Sort-Object LocalName -Descending)) {
            [void]$credentials.AppendChild($child)
        }
    }
    Assert-True ($omittedNames -gt 0) 'The client-saved fixture did not omit any default display names.'
    $clientSaved.Save($script:Target)
    Assert-NoOp 'Client-saved omitted defaults and reordered properties'
    $consoleChange = $clientSaved.CloneNode($true)
    $consoleChange.SelectSingleNode('//server/properties/connectionType').InnerText = 'VirtualMachineConsoleConnect'
    Assert-True (Test-RDCManConnectionDataChanged -Before $clientSaved -After $consoleChange) 'A genuine connection-type change was normalized away.'
    $script:Settings = [pscustomobject](Get-RDCSettingsDefaults)
    Invoke-Refresh
    Assert-Refreshed 'Restoring decorated display names'

    [xml]$ui = [IO.File]::ReadAllText($script:Target)
    foreach ($expanded in $ui.SelectNodes('//properties/expanded')) { $expanded.InnerText = 'False' }
    $ui.Save($script:Target)
    Assert-NoOp 'User expansion-state changes'

    foreach ($setting in @('AllVMsGroup', 'RoleGroups', 'OSGroups', 'SubnetGroups', 'SiteCodeGroups')) {
        $script:Settings.$setting = $true
        Invoke-Refresh
        Assert-Refreshed "Enabling $setting"
        Assert-NoOp "$setting second pass"
    }
    $script:Settings.DefaultGrouping = $false
    Invoke-Refresh
    Assert-Refreshed 'Disabling default grouping'
    Assert-NoOp 'Additive-only grouping second pass'

    $script:Settings.ShowOS = $false
    Invoke-Refresh
    Assert-Refreshed 'Display-name setting change'
    Assert-NoOp 'Updated display-name second pass'

    $script:FixturePassword = 'synthetic-rdcman-changed'
    Invoke-Refresh
    Assert-Refreshed 'Credential password change'
    Assert-NoOp 'Same password with newly randomized ciphertext'
    $client | Add-Member -NotePropertyName domainUser -NotePropertyValue 'testuser'
    Invoke-Refresh
    Assert-Refreshed 'Per-VM username change'
    Assert-NoOp 'Per-VM credential second pass'

    $client | Add-Member -NotePropertyName rdpCertSha256 -NotePropertyValue ('A' * 64)
    Invoke-Refresh
    Assert-Refreshed 'RDP certificate pin change'
    Assert-NoOp 'Unchanged certificate second pass'
    [xml]$attributeOrder = [IO.File]::ReadAllText($script:Target)
    foreach ($certificate in @($attributeOrder.SelectNodes('//trustedCertificates/certificate'))) {
        foreach ($attribute in @($certificate.Attributes | Sort-Object Name -Descending)) {
            [void]$certificate.Attributes.Remove($attribute)
            [void]$certificate.Attributes.Append($attribute)
        }
    }
    $attributeOrder.Save($script:Target)
    Assert-NoOp 'Client-saved certificate attribute ordering'

    $extra = [pscustomobject]@{
        vmName = 'LAB-EXTRA'; Role = 'DomainMember'; Domain = 'lab.test'; deployedOS = 'Windows 11 latest'
        LastKnownIP = '192.0.2.15'; network = '192.0.2.0'; state = 'Off'
    }
    $script:Inventory += $extra
    Invoke-Refresh
    Assert-Refreshed 'Adding a VM'
    Assert-NoOp 'Added VM second pass'
    $script:Inventory = @($script:Inventory | Where-Object vmName -ne 'LAB-EXTRA')
    Invoke-Refresh
    Assert-Refreshed 'Removing a VM'

    $script:UseRealSettings = $true
    $script:State.Running = $false
    $null = Save-RdcManSettingsFile -rdcmanfile $script:Target
    $settingsPath = Join-Path $env:LOCALAPPDATA 'Microsoft\Remote Desktop Connection Manager\RDCMan.settings'
    Assert-True ([IO.File]::Exists($settingsPath)) 'The real settings writer did not create its isolated fixture.'
    $settingsBefore = [IO.File]::ReadAllText($settingsPath)
    $settingsTime = [IO.File]::GetLastWriteTimeUtc($settingsPath)
    $script:State.Running = $true
    Assert-NoOp 'Unchanged RDG with real settings reconciliation'
    Assert-True ([IO.File]::ReadAllText($settingsPath) -ceq $settingsBefore -and
        [IO.File]::GetLastWriteTimeUtc($settingsPath) -eq $settingsTime) 'Unchanged real RDCMan settings were rewritten.'

    Invoke-Refresh -OverWrite
    Assert-Refreshed 'Explicit overwrite'
    $before = [IO.File]::ReadAllText($script:Target)
    Invoke-Refresh -OverWrite -WhatIf
    Assert-True ($script:State.StopCalls -eq 0 -and $script:State.Starts -eq 0 -and
        [IO.File]::ReadAllText($script:Target) -ceq $before) 'WhatIf touched the client or RDG.'
    Invoke-Refresh -UseIP
    Assert-Refreshed 'Changing Windows connection endpoints to IPs'
    [xml]$ipFile = [IO.File]::ReadAllText($script:Target)
    Assert-True ($ipFile.SelectNodes('//server/properties/name[text()="192.0.2.11"]').Count -gt 0) 'IP-mode refresh did not write the new endpoint.'
    Assert-True (@($script:State.Logs | Where-Object { $_ -like 'Could not compare an RDCMan credential*' }).Count -eq 0) 'Real credential comparison failed.'
}
finally {
    $Global:newrdcmanpath = $previousRdcPath
    $env:LOCALAPPDATA = $previousLocalAppData
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction Stop
}
Write-Host "PASS -- $script:Assertions RDCMan no-op and meaningful-change assertions."
