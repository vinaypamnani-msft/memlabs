<#
.SYNOPSIS
    Re-applies (or clears) Hyper-V port-ACL "must use proxy" enforcement
    across every memlabs VM on the host.

.DESCRIPTION
    Wrapper around Set-VmProxyEnforcementForAllLabs. Useful when:
      * A lab was added/removed/edited outside the normal deploy flow and
        ACLs on other labs' VMs need a refresh.
      * Someone manually flipped a VM's useProxy in its VM Note and wants
        the host-side ACLs to catch up.
      * Troubleshooting "lab can't reach lab" after multi-lab edits.

    Idempotent: the function reads each VM's useProxy from its VM Note,
    re-stamps the proxy ACL band (weight 5000-5099) for opted-in Windows
    VMs, and clears any leftover band entries on opted-out VMs.

    Does NOT touch deployConfig, VM Notes, or any in-guest setting.

.PARAMETER WhatIf
    Report intended actions without changing any ACLs.

.EXAMPLE
    .\Repair-ProxyAcls.ps1
    Reconcile every memlabs VM against the current global subnet union.

.EXAMPLE
    .\Repair-ProxyAcls.ps1 -WhatIf
    Show what would happen without making changes.
#>

#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = 'Stop'

# Dot-source the memlabs common runtime (same pattern as New-Lab.ps1).
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'Common.ps1') | Out-Null

if (-not (Get-Command Set-VmProxyEnforcementForAllLabs -ErrorAction SilentlyContinue)) {
    Write-Error "Set-VmProxyEnforcementForAllLabs is not loaded. Make sure Common.HyperV.ps1 dot-sourced cleanly."
    exit 1
}

Write-Host "[Repair-ProxyAcls] Starting cross-lab proxy ACL reconciliation..." -ForegroundColor Cyan
$ok = Set-VmProxyEnforcementForAllLabs -WhatIf:$WhatIfPreference
if ($ok) {
    Write-Host "[Repair-ProxyAcls] Reconciliation complete." -ForegroundColor Green
    exit 0
}
else {
    Write-Warning "[Repair-ProxyAcls] Reconciliation finished with one or more failures; check the memlabs log."
    exit 2
}
