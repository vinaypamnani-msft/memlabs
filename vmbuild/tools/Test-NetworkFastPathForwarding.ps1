<#
.SYNOPSIS
    Focused tests for host IPv4 forwarding in Test-NetworkFastPath.
#>
[CmdletBinding()]
param ([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0

function Assert-Equal {
    param ($Expected, $Actual, [string] $What)
    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) { Write-Host "      expected: $Expected`n      actual:   $Actual" }
}

function Import-TestFunction {
    param ([string] $Path, [string] $Name)
    $errors = $null; $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw "$Path has parse errors" }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition" }
    [scriptblock]::Create($definition[0].Extent.Text)
}

function Write-Log { param($Message, [switch]$LogOnly) }
function Write-GreenCheck { param($Message) }
function Write-OrangePoint { param($Message) }
function Start-DHCP { return $true }
function Get-DhcpServerv4Scope { return [pscustomobject]@{ ScopeId = '192.168.2.0' } }
$script:SetScopeOptions = $null
function Set-DhcpServerv4OptionValue {
    param($ScopeId, $Router, $DnsDomain, $WinsServer, $DnsServer, [switch]$Force)
    $script:SetScopeOptions = [pscustomobject]@{ ScopeId = $ScopeId; Router = $Router; DnsServer = $DnsServer }
}
$script:RouterOption = '192.168.2.200'
function Get-DhcpServerv4OptionValue {
    return @(
        [pscustomobject]@{ OptionID = 3; Value = $script:RouterOption }
        [pscustomobject]@{ OptionID = 6; Value = '192.168.2.1' }
    )
}

. (Import-TestFunction (Join-Path $RootPath 'Common.ps1') 'Test-NetworkFastPath')
. (Import-TestFunction (Join-Path $RootPath 'Common.ps1') 'Test-DHCPScope')

function New-NetworkCache {
    param (
        [string] $Forwarding = 'Enabled',
        [switch] $WithoutInterfaces,
        [string] $NetworkName = '192.168.2.0',
        [string] $NetworkSubnet = '192.168.2.0'
    )
    $gateway = $NetworkSubnet -replace '\.0$', '.200'
    $cache = @{
        Switches = @([pscustomobject]@{ Name = $NetworkName; Notes = 'example.test' })
        Adapters = @([pscustomobject]@{ Name = "vEthernet ($NetworkName)"; InterfaceAlias = "vEthernet ($NetworkName)"; InterfaceIndex = 42 })
        IPs = @([pscustomobject]@{ InterfaceAlias = "vEthernet ($NetworkName)"; IPAddress = $gateway })
        Nats = @([pscustomobject]@{ Name = $NetworkSubnet })
        Scopes = @([pscustomobject]@{ ScopeId = [pscustomobject]@{ IPAddressToString = $NetworkSubnet } })
        Interfaces = @([pscustomobject]@{ InterfaceIndex = 42; Forwarding = $Forwarding })
    }
    if ($WithoutInterfaces) { $cache.Remove('Interfaces') }
    return $cache
}

Write-Host "engine : $($PSVersionTable.PSVersion)"
$caseArgs = @{ NetworkName = '192.168.2.0'; NetworkSubnet = '192.168.2.0'; DomainName = 'example.test'; DNSServer = '192.168.2.1' }
Assert-Equal $true (Test-NetworkFastPath @caseArgs -Cache (New-NetworkCache)) 'fast path accepts a routed lab interface'
Assert-Equal $false (Test-NetworkFastPath @caseArgs -Cache (New-NetworkCache -Forwarding Disabled)) 'fast path rejects disabled IPv4 forwarding so the full path repairs it'
Assert-Equal $false (Test-NetworkFastPath @caseArgs -Cache (New-NetworkCache -WithoutInterfaces)) 'fast path rejects an unmeasured forwarding state'
$script:RouterOption = $null
Assert-Equal $false (Test-NetworkFastPath @caseArgs -Cache (New-NetworkCache)) 'fast path rejects a missing DHCP router option so the full path repairs it'
$script:RouterOption = '192.168.2.199'
Assert-Equal $false (Test-NetworkFastPath @caseArgs -Cache (New-NetworkCache)) 'fast path rejects a stale DHCP router option'
$script:RouterOption = $null
$script:SetScopeOptions = $null
Assert-Equal $true (Test-DHCPScope -ScopeID '192.168.2.0' -ScopeName '192.168.2.0' -DomainName 'example.test' -DNSServer '192.168.2.1') 'full scope path repairs a missing DHCP router option'
Assert-Equal '192.168.2.200' $script:SetScopeOptions.Router 'scope repair writes the host .200 gateway as DHCP option 3'
$clusterArgs = @{ NetworkName = 'Cluster'; NetworkSubnet = '10.250.250.0' }
Assert-Equal $true (Test-NetworkFastPath @clusterArgs -Cache (New-NetworkCache -NetworkName Cluster -NetworkSubnet '10.250.250.0')) 'fast path preserves the Cluster scope contract with no DHCP router option'
$script:SetScopeOptions = $null
Assert-Equal $true (Test-DHCPScope -ScopeID '10.250.250.0' -ScopeName 'cluster') 'full scope path accepts the intentional optionless Cluster scope'
Assert-Equal $true ($null -eq $script:SetScopeOptions) 'Cluster scope repair does not add DHCP options'

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All network fast-path forwarding checks passed.'
