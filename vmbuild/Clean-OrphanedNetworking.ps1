<#
.SYNOPSIS
    Identifies and removes orphaned NAT entries, DHCP scopes, and Hyper-V
    switches that no longer have any VMs attached.

.DESCRIPTION
    Enumerates all memlabs VMs via Get-List to determine which networks are
    in use, then compares against host-level NetNat, DHCP, and VMSwitch
    definitions. Anything not backing a live VM is flagged as orphaned.

    By default runs in report-only mode. Use -Remove to actually delete.

.PARAMETER Remove
    Actually remove orphaned entries instead of just reporting them.

.PARAMETER Force
    Skip confirmation prompts when -Remove is specified.

.EXAMPLE
    .\Clean-OrphanedNetworking.ps1
    # Report only — shows what would be removed

.EXAMPLE
    .\Clean-OrphanedNetworking.ps1 -Remove
    # Interactive — prompts before each removal

.EXAMPLE
    .\Clean-OrphanedNetworking.ps1 -Remove -Force
    # Non-interactive — removes all orphaned entries without prompting
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$Force
)

# ── Bootstrap memlabs environment ────────────────────────────────────────────
if ($Common.Initialized) {
    $Common.Initialized = $false
}

Push-Location $PSScriptRoot
try {
    . $PSScriptRoot\Common.ps1 -VerboseEnabled:$false
}
catch {
    Write-Host "ERROR: Failed to load Common.ps1. Run this from the vmbuild directory." -ForegroundColor Red
    exit 1
}

# ── Gather networks in use ───────────────────────────────────────────────────
# Get-List -Type UniqueSwitch returns switch names like "192.168.8.0", "Internet", "Cluster"
$networksInUse = @(Get-List -Type UniqueSwitch -SmartUpdate)

# Shared infrastructure switches (Internet, Cluster, ClusterV2) are protected
# only when VMs are actually connected to them. If no VMs use them, they're
# genuinely orphaned and safe to clean up.
foreach ($infra in @('Internet', 'Cluster', 'ClusterV2')) {
    if ($networksInUse -notcontains $infra) {
        $sw = Get-VMSwitch -Name $infra -ErrorAction SilentlyContinue
        if ($sw) {
            $attached = @(Get-VM | Get-VMNetworkAdapter -ErrorAction SilentlyContinue |
                Where-Object { $_.SwitchName -eq $infra })
            if ($attached.Count -gt 0) {
                $networksInUse += $infra
            }
        }
    }
}

# NAT entries use subnet names (e.g. "192.168.8.0"), while switches named
# "Internet" map to subnet 172.31.250.0 and "Cluster" to 10.250.250.0.
$subnetsInUse = @($networksInUse | ForEach-Object {
    switch ($_) {
        'Internet'  { '172.31.250.0' }
        'Cluster'   { '10.250.250.0' }
        'ClusterV2' { '10.250.251.0' }
        default     { $_ }
    }
})

Write-Host
Write-Host "Networks in use by VMs: $($networksInUse.Count)" -ForegroundColor Cyan
foreach ($n in ($networksInUse | Sort-Object)) {
    Write-Host "  $n" -ForegroundColor DarkGray
}
Write-Host

# ── Helper: prompt or auto-approve ───────────────────────────────────────────
function Confirm-Removal {
    param([string]$Description)
    if (-not $Remove) { return $false }
    if ($Force) { return $true }
    $response = Read-Host "  Remove ${Description}? [y/N]"
    return ($response -and $response.Trim().ToLowerInvariant() -eq 'y')
}

# ── Track totals ─────────────────────────────────────────────────────────────
$stats = @{ NAT = @{ Found = 0; Removed = 0 }; DHCP = @{ Found = 0; Removed = 0 }; Switch = @{ Found = 0; Removed = 0 }; Reservation = @{ Found = 0; Removed = 0 } }

# ── 1. Orphaned NAT entries ─────────────────────────────────────────────────
Write-Host "=== Orphaned NAT Entries ===" -ForegroundColor Yellow
$natEntries = @(Get-NetNat -ErrorAction SilentlyContinue)
foreach ($nat in $natEntries) {
    # Only consider memlabs-style NATs named with a dotted-quad subnet
    if ($nat.Name -notmatch '^\d+\.\d+\.\d+\.\d+$') { continue }
    if ($subnetsInUse -contains $nat.Name) { continue }

    $stats.NAT.Found++
    $label = "NAT '$($nat.Name)' ($($nat.InternalIPInterfaceAddressPrefix))"
    if (-not $Remove) {
        Write-Host "  [orphaned] $label" -ForegroundColor Red
    }
    elseif (Confirm-Removal $label) {
        Remove-NetNat -Name $nat.Name -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "  [removed]  $label" -ForegroundColor Green
        $stats.NAT.Removed++
    }
    else {
        Write-Host "  [skipped]  $label" -ForegroundColor DarkGray
    }
}
if ($stats.NAT.Found -eq 0) {
    Write-Host "  None found." -ForegroundColor DarkGray
}
Write-Host

# ── 2. Orphaned DHCP Scopes ─────────────────────────────────────────────────
Write-Host "=== Orphaned DHCP Scopes ===" -ForegroundColor Yellow
$dhcpAvailable = $null -ne (Get-Command Get-DhcpServerv4Scope -ErrorAction SilentlyContinue)
if ($dhcpAvailable) {
    $scopes = @(Get-DhcpServerv4Scope -ErrorAction SilentlyContinue)
    foreach ($scope in $scopes) {
        $scopeId = $scope.ScopeId.ToString()
        if ($subnetsInUse -contains $scopeId) { continue }

        $stats.DHCP.Found++
        $label = "DHCP scope '$($scope.Name)' [$scopeId]"
        if (-not $Remove) {
            Write-Host "  [orphaned] $label" -ForegroundColor Red
        }
        elseif (Confirm-Removal $label) {
            Remove-DhcpServerv4Scope -ScopeId $scopeId -Force -ErrorAction SilentlyContinue
            Write-Host "  [removed]  $label" -ForegroundColor Green
            $stats.DHCP.Removed++
        }
        else {
            Write-Host "  [skipped]  $label" -ForegroundColor DarkGray
        }
    }
    if ($stats.DHCP.Found -eq 0) {
        Write-Host "  None found." -ForegroundColor DarkGray
    }
}
else {
    Write-Host "  DHCP Server cmdlets not available — skipping." -ForegroundColor DarkGray
}
Write-Host

# ── 3. Orphaned Hyper-V Switches ────────────────────────────────────────────
Write-Host "=== Orphaned Hyper-V Switches ===" -ForegroundColor Yellow
$switches = @(Get-VMSwitch -SwitchType Internal -ErrorAction SilentlyContinue)
foreach ($sw in $switches) {
    # Only consider switches that look like memlabs created them:
    # subnet-named (e.g. "192.168.1.0") or well-known names.
    $isMemlabs = $sw.Name -match '^\d+\.\d+\.\d+\.\d+$' -or
                 $sw.Name -in @('Internet', 'Cluster', 'ClusterV2', 'MemLabsNAT')
    if (-not $isMemlabs) { continue }

    $inUse = $false
    foreach ($network in $networksInUse) {
        if ($sw.Name -like "*$network*") {
            $inUse = $true
            break
        }
    }
    if ($inUse) { continue }

    $stats.Switch.Found++
    $label = "switch '$($sw.Name)'"
    if (-not $Remove) {
        Write-Host "  [orphaned] $label" -ForegroundColor Red
    }
    elseif (Confirm-Removal $label) {
        # Remove the vEthernet adapter IP first (it goes away with the switch,
        # but being explicit avoids races)
        $sw | Remove-VMSwitch -Force -ErrorAction SilentlyContinue
        Write-Host "  [removed]  $label" -ForegroundColor Green
        $stats.Switch.Removed++
    }
    else {
        Write-Host "  [skipped]  $label" -ForegroundColor DarkGray
    }
}
if ($stats.Switch.Found -eq 0) {
    Write-Host "  None found." -ForegroundColor DarkGray
}
Write-Host

# ── 4. Orphaned DHCP Reservations (within in-use scopes) ────────────────────
# A reservation is legitimate only while its MAC is attached to the vSwitch
# that serves the scope. The switch is created as New-VMSwitch -Name <network>,
# so for domain scopes the switch name equals the scope id. Any reservation
# whose MAC is NOT a current member of that switch is an orphan -- left by a
# deleted VM, or by a VM that now lives on a different switch (e.g. a capture
# box). Powered-off lab VMs are still switch members, so they are never
# flagged. Shared-infra scopes (Internet/Cluster/ClusterV2) use a switch whose
# name differs from the scope id, so no name-matching switch is found and the
# scope is skipped -- we never sweep reservations we can't authoritatively own.
Write-Host "=== Orphaned DHCP Reservations ===" -ForegroundColor Yellow
if ($dhcpAvailable) {
    foreach ($scope in @(Get-DhcpServerv4Scope -ErrorAction SilentlyContinue)) {
        $scopeId = $scope.ScopeId.ToString()

        # Only sweep domain scopes whose vSwitch is named after the network.
        $scopeSwitch = Get-VMSwitch -Name $scopeId -ErrorAction SilentlyContinue
        if (-not $scopeSwitch) { continue }

        # MACs currently attached to this scope's switch (any power state).
        $memberMacs = @{}
        Get-VM | Get-VMNetworkAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.SwitchName -eq $scopeId -and $_.MacAddress -and $_.MacAddress -ne '000000000000' } |
            ForEach-Object { $memberMacs[($_.MacAddress -replace '[-:]', '').ToLower()] = $_.VMName }

        foreach ($res in @(Get-DhcpServerv4Reservation -ScopeId $scopeId -ErrorAction SilentlyContinue)) {
            $resMac = ($res.ClientId -replace '[-:]', '').ToLower()
            if ($memberMacs.ContainsKey($resMac)) { continue }   # live switch member -- keep

            $stats.Reservation.Found++
            $label = "reservation $($res.IPAddress) [$($res.ClientId)] in scope $scopeId"
            if (-not $Remove) {
                Write-Host "  [orphaned] $label" -ForegroundColor Red
            }
            elseif (Confirm-Removal $label) {
                Remove-DhcpServerv4Reservation -IPAddress $res.IPAddress -ErrorAction SilentlyContinue
                Remove-DhcpServerv4Lease -IPAddress $res.IPAddress -ErrorAction SilentlyContinue
                Write-Host "  [removed]  $label" -ForegroundColor Green
                $stats.Reservation.Removed++
            }
            else {
                Write-Host "  [skipped]  $label" -ForegroundColor DarkGray
            }
        }
    }
    if ($stats.Reservation.Found -eq 0) {
        Write-Host "  None found." -ForegroundColor DarkGray
    }
}
else {
    Write-Host "  DHCP Server cmdlets not available — skipping." -ForegroundColor DarkGray
}
Write-Host

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Host "=== Summary ===" -ForegroundColor Cyan
$totalFound   = $stats.NAT.Found + $stats.DHCP.Found + $stats.Switch.Found + $stats.Reservation.Found
$totalRemoved = $stats.NAT.Removed + $stats.DHCP.Removed + $stats.Switch.Removed + $stats.Reservation.Removed

Write-Host "  NAT entries : $($stats.NAT.Found) orphaned" -NoNewline
if ($Remove) { Write-Host ", $($stats.NAT.Removed) removed" -ForegroundColor Green } else { Write-Host }

Write-Host "  DHCP scopes : $($stats.DHCP.Found) orphaned" -NoNewline
if ($Remove) { Write-Host ", $($stats.DHCP.Removed) removed" -ForegroundColor Green } else { Write-Host }

Write-Host "  Switches    : $($stats.Switch.Found) orphaned" -NoNewline
if ($Remove) { Write-Host ", $($stats.Switch.Removed) removed" -ForegroundColor Green } else { Write-Host }

Write-Host "  Reservations: $($stats.Reservation.Found) orphaned" -NoNewline
if ($Remove) { Write-Host ", $($stats.Reservation.Removed) removed" -ForegroundColor Green } else { Write-Host }

Write-Host
if (-not $Remove -and $totalFound -gt 0) {
    Write-Host "Run with -Remove to delete orphaned entries, or -Remove -Force to skip prompts." -ForegroundColor Yellow
}
elseif ($Remove -and $totalRemoved -gt 0) {
    Write-Host "Tip: Run 'Restart-Service WinNat' if NATs were removed to refresh the NAT driver." -ForegroundColor Yellow
}

Pop-Location
