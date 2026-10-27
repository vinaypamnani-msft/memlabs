<#
.SYNOPSIS
    Verifies domain-controller readiness handles exact-main BDCs without DNS.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$phasesPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'common\Common.Phases.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($phasesPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) {
    throw "Common.Phases.ps1 has parse errors: $($parseErrors -join '; ')"
}
$definitions = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-MemLabsDomainControllerReadinessProbe'
        }, $true))
if ($definitions.Count -ne 1) {
    throw "Expected one Get-MemLabsDomainControllerReadinessProbe definition, found $($definitions.Count)."
}
. ([scriptblock]::Create($definitions[0].Extent.Text))

$script:ServiceStates = @{}
function Get-Service {
    param([string] $Name, [Parameter(ValueFromRemainingArguments = $true)] $Remaining)
    if (-not $script:ServiceStates.ContainsKey($Name)) { return $null }
    [pscustomobject]@{ Name = $Name; Status = $script:ServiceStates[$Name] }
}
function Invoke-ReadinessProbe {
    param([string] $Role, [hashtable] $Services)
    $script:ServiceStates = $Services
    & (Get-MemLabsDomainControllerReadinessProbe) $Role
}
function Assert-Ready {
    param([bool] $Expected, [object] $Actual, [string] $Message)
    if ([bool]$Actual.Ready -ne $Expected) {
        throw "$Message`nExpected Ready=$Expected`nActual: $($Actual | ConvertTo-Json -Compress)"
    }
}

$runningDirectory = @{ Netlogon = 'Running'; NTDS = 'Running' }
Assert-Ready $true (Invoke-ReadinessProbe -Role BDC -Services $runningDirectory) `
    'An exact-main BDC without DNS must satisfy directory-service readiness.'
Assert-Ready $false (Invoke-ReadinessProbe -Role DC -Services $runningDirectory) `
    'A primary DC without DNS must not satisfy readiness.'
Assert-Ready $true (Invoke-ReadinessProbe -Role BDC -Services ($runningDirectory + @{ DNS = 'Running' })) `
    'A modern BDC with running DNS must satisfy readiness.'
Assert-Ready $false (Invoke-ReadinessProbe -Role BDC -Services ($runningDirectory + @{ DNS = 'Stopped' })) `
    'An installed but stopped BDC DNS service must fail readiness.'
Assert-Ready $false (Invoke-ReadinessProbe -Role BDC -Services @{ Netlogon = 'Running'; NTDS = 'Stopped' }) `
    'A BDC with stopped AD DS must fail readiness.'

Write-Host 'PASS -- DC readiness supports legacy no-DNS BDCs and requires every installed directory service.'
