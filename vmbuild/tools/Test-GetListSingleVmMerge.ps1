<#
.SYNOPSIS
    Verifies Get-List can merge deployConfig data when only one VM is cached.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'common\Common.Config.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)

if ($parseErrors.Count -gt 0) {
    throw "Common.Config.ps1 has $($parseErrors.Count) parse error(s): $($parseErrors -join '; ')"
}

$source = Get-Content -LiteralPath $sourcePath -Raw
foreach ($required in @(
        '$return = @($global:vm_List)',
        '$return = @($return | Where-Object { $_.vmName -ne $vm.vmName })',
        '$return = @($return | Sort-Object -Property *)')) {
    if (-not $source.Contains($required)) {
        throw "Get-List is missing scalar-safe array normalization: $required"
    }
}

# Exercise the same one-existing/one-new merge shape that failed in NOCM-B.
$global:vm_List = [pscustomobject]@{ vmName = 'NOC-DC1'; source = 'hyperv' }
$return = @($global:vm_List)
$newVm = [pscustomobject]@{ vmName = 'NOC-W11CLIENT1'; source = 'config' }
$return += $newVm
$return = @($return | Sort-Object vmName)
if ($return.Count -ne 2 -or @($return.vmName) -notcontains 'NOC-DC1' -or @($return.vmName) -notcontains 'NOC-W11CLIENT1') {
    throw "Scalar-safe VM merge failed: $($return | ConvertTo-Json -Compress)"
}

# Exercise the replacement branch: filtering a two-item list down to one must
# still leave an array before the replacement is appended.
$return = @(
    [pscustomobject]@{ vmName = 'NOC-DC1'; source = 'hyperv' },
    [pscustomobject]@{ vmName = 'NOC-W11CLIENT1'; source = 'hyperv'; memory = '2GB' }
)
$replacement = [pscustomobject]@{ vmName = 'NOC-W11CLIENT1'; source = 'config'; memory = '4GB' }
$return = @($return | Where-Object { $_.vmName -ne $replacement.vmName })
$return += $replacement
if ($return.Count -ne 2 -or
    @($return | Where-Object { $_.vmName -eq 'NOC-W11CLIENT1' -and $_.memory -eq '4GB' }).Count -ne 1) {
    throw "Scalar-safe same-name replacement failed: $($return | ConvertTo-Json -Compress)"
}

$global:vm_List = $null
Write-Host 'PASS -- Get-List preserves array semantics for one cached VM plus one config VM.'
