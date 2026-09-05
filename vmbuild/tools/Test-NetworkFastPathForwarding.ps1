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
function Get-DhcpServerv4OptionValue { return @([pscustomobject]@{ OptionID = 6; Value = '192.168.2.1' }) }

. (Import-TestFunction (Join-Path $RootPath 'Common.ps1') 'Test-NetworkFastPath')

function New-NetworkCache {
    param ([string] $Forwarding = 'Enabled', [switch] $WithoutInterfaces)
    $cache = @{
        Switches = @([pscustomobject]@{ Name = '192.168.2.0'; Notes = 'example.test' })
        Adapters = @([pscustomobject]@{ Name = 'vEthernet (192.168.2.0)'; InterfaceAlias = 'vEthernet (192.168.2.0)'; InterfaceIndex = 42 })
        IPs = @([pscustomobject]@{ InterfaceAlias = 'vEthernet (192.168.2.0)'; IPAddress = '192.168.2.200' })
        Nats = @([pscustomobject]@{ Name = '192.168.2.0' })
        Scopes = @([pscustomobject]@{ ScopeId = [pscustomobject]@{ IPAddressToString = '192.168.2.0' } })
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

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All network fast-path forwarding checks passed.'
