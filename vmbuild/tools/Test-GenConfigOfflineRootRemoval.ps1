<#
.SYNOPSIS
    Verifies GenConfig confirmation and persistence when removing an Offline Root CA.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$commonPath = Join-Path $RootPath 'common'

function Import-TestFunction {
    param([string] $File, [string] $Name)

    $path = Join-Path $commonPath $File
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref] $tokens, [ref] $errors)
    if ($errors.Count) { throw "$path has parse errors: $($errors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition, found $($definitions.Count)." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Message)

    $script:Assertions++
    if ("$Expected" -ne "$Actual") { throw "$Message`nExpected: $Expected`nActual: $Actual" }
}

function Get-FixtureState {
    $global:Config | ConvertTo-Json -Depth 10 -Compress
}

function Reset-Fixture {
    param([bool] $AutoAdded = $true)

    $script:Answer = 'y'
    $script:Prompts = New-Object 'System.Collections.Generic.List[object]'
    $script:AutoAdds = 0
    $global:existingMachines = @()
    $global:GenConfigErrorMessages = @()
    $global:PendingValidationErrors = @()
    $global:Config = [pscustomobject]@{
        vmOptions       = [pscustomobject]@{ domainName = 'example.test'; prefix = 'T-' }
        domainDefaults  = [pscustomobject]@{ DefaultServerOS = 'Server 2022' }
        pkiOptions      = [pscustomobject]@{
            EnablePKI = $true; IssuingCAVM = 'T-DC1'; UseOfflineRoot = $true; OfflineRootCAVM = 'T-ROOTCA'
        }
        cmOptions       = [pscustomobject]@{ UsePKI = $true }
        virtualMachines = @(
            [pscustomobject]@{ vmName = 'T-DC1'; Role = 'DC'; operatingSystem = 'Server 2022' },
            [pscustomobject]@{ vmName = 'T-ROOTCA'; Role = 'StandaloneRootCA'; operatingSystem = 'Server 2022' },
            [pscustomobject]@{ vmName = 'T-MEMBER1'; Role = 'DomainMember'; operatingSystem = 'Server 2022' }
        )
    }
    if ($AutoAdded) {
        $global:Config.virtualMachines[1] | Add-Member -NotePropertyName '_autoAddedByOfflineRootCA' -NotePropertyValue $true
    }
}

function Write-Log {
    param($Message, [switch] $Activity, [switch] $NoNewLine, [switch] $LogOnly, [switch] $HostOnly, [switch] $Verbose)
}
function Add-ErrorMessage {
    param($Message, $Property, [switch] $Persist)
    throw "Unexpected GenConfig error: $Message"
}
function Test-VmIsLinux { param($VM) $false }
function Get-DiskShortSummary { param($VirtualMachine) 'No data disks' }
function Get-VMDiskLetters { param($VirtualMachine) @() }
function Select-Options { 'Z' }
function Read-YesOrNoWithTimeout {
    param($Prompt, [switch] $HideHelp, $Default, $Timeout)

    $script:Prompts.Add([pscustomobject]@{ Prompt = $Prompt; Default = $Default })
    if ($script:Answer -eq 'DEFAULT') { return $Default }
    $script:Answer
}
function Get-List { param($Type, $DomainName) @() }
function Add-NewVMForRole {
    param($Role, $Domain, $ConfigToModify, $OperatingSystem, [bool] $Quiet)

    $script:AutoAdds++
    $ConfigToModify.virtualMachines += [pscustomobject]@{
        vmName = 'T-AUTOROOT'; Role = $Role; operatingSystem = $OperatingSystem
    }
}
function Get-TestResult { throw 'Deleting a VM should not run property validation.' }
function Remove-VirtualMachine { throw 'This regression check must not delete deployed VMs.' }

foreach ($name in 'Select-VirtualMachines', 'Remove-VMFromConfig') {
    . (Import-TestFunction 'Common.GenConfig.VMList.ps1' $name)
}
foreach ($name in 'Add-OfflineRootCAVMIfMissing', 'Remove-OfflineRootCAVMIfAutoAdded', 'Clear-StaleValidationMessagesForVM') {
    . (Import-TestFunction 'Common.GenConfig.AddVM.ps1' $name)
}

$savedGlobals = @{}
foreach ($name in 'Config', 'Common', 'existingMachines', 'GenConfigErrorMessages', 'PendingValidationErrors') {
    $variable = Get-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue
    $savedGlobals[$name] = [pscustomobject]@{ Exists = ($null -ne $variable); Value = $variable.Value }
}
$script:Assertions = 0
try {
    $global:Common = [pscustomobject]@{
        Colors = [pscustomobject]@{ GenConfigHeader = 'Gray'; GenConfigDangerous = 'Red' }
    }

    # Prove the redraw helper recreates a removed root while the option remains enabled.
    Reset-Fixture
    Remove-VMFromConfig -vmName 'T-ROOTCA'
    Add-OfflineRootCAVMIfMissing
    Assert-Equal 1 $script:AutoAdds 'The fixture did not reproduce Offline Root auto-creation.'
    Assert-Equal 1 @($global:Config.virtualMachines | Where-Object Role -eq 'StandaloneRootCA').Count 'The redraw helper did not create an Offline Root VM.'

    foreach ($autoAdded in $true, $false) {
        foreach ($useMenu in $true, $false) {
            foreach ($confirmation in 'y', 'Y', 'yes') {
                Reset-Fixture -AutoAdded $autoAdded
                $script:Answer = $confirmation
                $dc = $global:Config.virtualMachines[0]
                if ($useMenu) { Select-VirtualMachines -response 'T-ROOTCA' }
                else { Select-VirtualMachines -response 'T-ROOTCA' -result 'Z' }

                Assert-Equal $false $global:Config.pkiOptions.UseOfflineRoot 'Accepting removal did not disable Offline Root.'
                Assert-Equal '' $global:Config.pkiOptions.OfflineRootCAVM 'Accepting removal left a stale Offline Root CA reference.'
                Assert-Equal 0 @($global:Config.virtualMachines | Where-Object vmName -eq 'T-ROOTCA').Count 'Accepting removal did not remove the VM.'
                Assert-Equal 1 $script:Prompts.Count 'Offline Root removal should use a single combined confirmation.'
                Assert-Equal $true ($script:Prompts[0].Prompt -match 'disable.*offline root') 'The confirmation did not explain disabling Offline Root.'
                Assert-Equal 'n' $script:Prompts[0].Default 'Offline Root removal should require affirmative confirmation.'
                Assert-Equal $true $global:Config.pkiOptions.EnablePKI 'Removing the Offline Root disabled PKI infrastructure.'
                Assert-Equal 'T-DC1' $global:Config.pkiOptions.IssuingCAVM 'Removing the Offline Root changed the Issuing CA selection.'
                Assert-Equal $true $global:Config.cmOptions.UsePKI 'Removing the Offline Root disabled ConfigMgr HTTPS.'
                Assert-Equal $true ([object]::ReferenceEquals($dc, $global:Config.virtualMachines[0])) 'Removing the root detached another VM from the live configuration.'

                $global:Config = Get-FixtureState | ConvertFrom-Json
                foreach ($pass in 1..2) {
                    Add-OfflineRootCAVMIfMissing
                    Remove-OfflineRootCAVMIfAutoAdded
                }
                Assert-Equal 0 $script:AutoAdds 'The removed Offline Root was recreated after saving and redrawing.'
                Assert-Equal 0 @($global:Config.virtualMachines | Where-Object Role -eq 'StandaloneRootCA').Count 'The removed Offline Root returned on a later menu pass.'
                Assert-Equal 'T-DC1,T-MEMBER1' ($global:Config.virtualMachines.vmName -join ',') 'Removing the root changed unrelated VMs.'
            }
        }
    }

    foreach ($autoAdded in $true, $false) {
        foreach ($confirmation in @('n', 'N', 'no', 'ESCAPE', $null, '', 'DEFAULT')) {
            Reset-Fixture -AutoAdded $autoAdded
            $script:Answer = $confirmation
            $before = Get-FixtureState
            Select-VirtualMachines -response 'T-ROOTCA' -result 'Z'
            Assert-Equal $before (Get-FixtureState) "Declining Offline Root removal ('$confirmation') changed the configuration."
            Assert-Equal 1 $script:Prompts.Count 'Declining Offline Root removal did not stop at the confirmation.'
            Assert-Equal 'n' $script:Prompts[0].Default 'The default should cancel Offline Root removal.'
            Add-OfflineRootCAVMIfMissing
            Remove-OfflineRootCAVMIfAutoAdded
            Assert-Equal $before (Get-FixtureState) 'Declining removal did not preserve the root on redraw.'
        }
    }

    foreach ($confirmation in 'y', 'DEFAULT', 'n') {
        Reset-Fixture
        $script:Answer = $confirmation
        $pkiBefore = $global:Config.pkiOptions | ConvertTo-Json -Compress
        Select-VirtualMachines -response 'T-MEMBER1' -result 'Z'
        $expectedCount = if ($confirmation -eq 'n') { 1 } else { 0 }
        Assert-Equal $expectedCount @($global:Config.virtualMachines | Where-Object vmName -eq 'T-MEMBER1').Count 'Ordinary VM removal changed its confirmation behavior.'
        Assert-Equal $pkiBefore ($global:Config.pkiOptions | ConvertTo-Json -Compress) 'Ordinary VM removal changed PKI settings.'
        Assert-Equal 1 $script:Prompts.Count 'Ordinary VM removal added an extra confirmation.'
        Assert-Equal 'y' $script:Prompts[0].Default 'Ordinary VM removal changed its existing default.'
        Assert-Equal $false ($script:Prompts[0].Prompt -match 'offline root') 'Ordinary VM removal mentioned Offline Root.'
    }

    Reset-Fixture -AutoAdded $false
    $global:Config.pkiOptions.UseOfflineRoot = $false
    $global:Config.pkiOptions.OfflineRootCAVM = ''
    Select-VirtualMachines -response 'T-ROOTCA' -result 'Z'
    Assert-Equal 0 @($global:Config.virtualMachines | Where-Object Role -eq 'StandaloneRootCA').Count 'An unused Root CA VM could not be removed.'
    Assert-Equal 'y' $script:Prompts[0].Default 'An already-disabled Offline Root should use ordinary removal confirmation.'

    Reset-Fixture
    $global:Config.PSObject.Properties.Remove('pkiOptions')
    Select-VirtualMachines -response 'T-MEMBER1' -result 'Z'
    Assert-Equal 0 @($global:Config.virtualMachines | Where-Object vmName -eq 'T-MEMBER1').Count 'VM removal failed without PKI options.'

    Write-Host "PASS: $($script:Assertions) assertions cover Offline Root confirmation, cancellation, persistent deletion and ordinary VM removal." -ForegroundColor Green
}
finally {
    foreach ($name in $savedGlobals.Keys) {
        if ($savedGlobals[$name].Exists) { Set-Variable -Name $name -Scope Global -Value $savedGlobals[$name].Value }
        else { Remove-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue }
    }
}
