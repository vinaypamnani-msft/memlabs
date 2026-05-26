<#
.SYNOPSIS
    Re-seed a memlabs Linux VM with new cloud-init runcmd to recover networking.

.DESCRIPTION
    Hyper-V's Msvm_Keyboard.TypeText is unreliable - it synthesizes scan codes
    without timing, the Linux input layer interprets the result as key-repeat,
    and you end up with garbled junk like "ddxxdx" instead of your commands.

    This script takes a different approach: build a brand-new cloud-init NoCloud
    seed ISO with the recovery commands baked into runcmd, then swap the VM's
    existing seed DVD to point at it. cloud-init sees a NEW instance-id and
    re-runs everything (including runcmd) on the next boot.

    The only thing you have to type at the console is:   sudo reboot

    Workflow:
      1. Builds new seed ISO at  <vm.Path>\<VmName>-seed-recover.iso  with
         the systemd-networkd recovery commands embedded in runcmd.
      2. Disconnects whatever ISO is currently attached as DVD.
      3. Attaches the new recovery seed ISO as DVD.
      4. Tells you to type 'sudo reboot' in the VM console.

    After the reboot, cloud-init re-runs, fixes the network, and the VM picks
    up a DHCP lease on its own. You can then SSH in from the host like normal:
        ssh vmbuildadmin@<that-ip>

.PARAMETER VMName
    Hyper-V VM name (e.g. CON-LINUXCLIENT1).

.PARAMETER Domain
    AD/DNS domain of the VM (e.g. contoso.com). Defaults to parsing it from
    the VM name prefix + the deployConfig.json sitting next to the VM, or
    you can pass it explicitly.

.PARAMETER KeepCurrentDvd
    Instead of replacing the existing DVD, ADD the recovery ISO as a second
    DVD drive. Use this if you want to inspect the original seed ISO later.

.EXAMPLE
    .\Reseed-LinuxVM.ps1 -VMName CON-LINUXCLIENT1 -Domain contoso.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$VMName,

    [Parameter(Mandatory)]
    [string]$Domain,

    [switch]$KeepCurrentDvd
)

$ErrorActionPreference = 'Stop'

# Pull in memlabs Linux helpers (New-LinuxSeedIso, Get-LinuxAdminSshKeyPair, ...)
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot '..')
. (Join-Path $repoRoot 'Common.ps1') -VerboseEnabled:$false

$vm = Get-VM -Name $VMName -ErrorAction Stop
$seedPath = Join-Path $vm.Path "$VMName-seed-recover.iso"

# The recovery recipe. cloud-init runs each runcmd entry as a separate shell
# call, so we use bash -lc strings for any line that needs shell features.
$recoveryRunCmd = @(
    # Make sure the Desktop bake's NM-renderer override is gone so netplan
    # falls back to the systemd-networkd renderer.
    'rm -f /etc/cloud/cloud.cfg.d/99-network-renderer.cfg',
    # Unmask + enable systemd-networkd (Desktop bake disabled it).
    'systemctl unmask systemd-networkd || true',
    'systemctl enable systemd-networkd || true',
    # Drop a wildcard DHCP profile covering both eth* (legacy) and en* names.
    # Single-quoted PS string so $ / [ / backticks pass through unmolested;
    # printf inside bash interprets the \n escapes into real newlines.
    'bash -lc ''mkdir -p /etc/systemd/network && printf "[Match]\nName=eth* en*\n\n[Network]\nDHCP=yes\n" >/etc/systemd/network/10-memlabs-dhcp.network''',
    # Restart to apply.
    'systemctl restart systemd-networkd || true',
    # If NetworkManager is installed (Desktop variant), tell it to leave eth*
    # alone so the two don't race for the lease.
    'bash -lc ''if command -v nmcli >/dev/null 2>&1; then mkdir -p /etc/NetworkManager/conf.d && printf "[keyfile]\nunmanaged-devices=interface-name:eth*\n" >/etc/NetworkManager/conf.d/10-memlabs-unmanage-eth.conf && systemctl restart NetworkManager || true; fi''',
    # Log the result somewhere visible.
    'ip -4 addr show > /var/log/memlabs-recover-ip.log 2>&1 || true'
)

Write-Host "Building recovery seed ISO for $VMName at:" -ForegroundColor Cyan
Write-Host "    $seedPath" -ForegroundColor DarkGray

$null = New-LinuxSeedIso `
    -VmName $VMName `
    -Domain $Domain `
    -OutputIsoPath $seedPath `
    -ExtraRunCmd $recoveryRunCmd

if (-not (Test-Path $seedPath)) { throw "Seed ISO build failed - $seedPath does not exist." }

if ($KeepCurrentDvd) {
    Write-Host "Attaching recovery ISO as an ADDITIONAL DVD drive..." -ForegroundColor Cyan
    Add-VMDvdDrive -VMName $VMName -Path $seedPath | Out-Null
} else {
    $existing = Get-VMDvdDrive -VMName $VMName
    if ($existing) {
        # Replace the first DVD's media in place. cloud-init's NoCloud
        # datasource just scans every block device with label 'cidata', so
        # whichever DVD has the new ISO will be picked up.
        $first = $existing | Select-Object -First 1
        Write-Host "Swapping DVD media on controller $($first.ControllerNumber) loc $($first.ControllerLocation) to recovery ISO..." -ForegroundColor Cyan
        Set-VMDvdDrive -VMName $VMName `
                       -ControllerNumber $first.ControllerNumber `
                       -ControllerLocation $first.ControllerLocation `
                       -Path $seedPath
        # If there were other DVDs, leave them; they shouldn't conflict, but
        # warn so you know.
        if ($existing.Count -gt 1) {
            Write-Host "Note: VM had $($existing.Count) DVD drives; only swapped the first. Others left alone." -ForegroundColor Yellow
        }
    } else {
        Write-Host "VM had no DVD drive; adding the recovery ISO..." -ForegroundColor Cyan
        Add-VMDvdDrive -VMName $VMName -Path $seedPath | Out-Null
    }
}

Write-Host ""
Write-Host "Recovery ISO attached. Now in the VM console (vmconnect), type:" -ForegroundColor Green
Write-Host "    sudo reboot" -ForegroundColor White
Write-Host ""
Write-Host "On the next boot cloud-init will:" -ForegroundColor DarkGray
Write-Host "  - re-enable systemd-networkd" -ForegroundColor DarkGray
Write-Host "  - write /etc/systemd/network/10-memlabs-dhcp.network" -ForegroundColor DarkGray
Write-Host "  - tell NetworkManager to ignore eth* (Desktop variants only)" -ForegroundColor DarkGray
Write-Host "  - log the resulting 'ip -4 addr show' to /var/log/memlabs-recover-ip.log" -ForegroundColor DarkGray
Write-Host ""
Write-Host "After it comes back up, check the lease from the host with:" -ForegroundColor Yellow
Write-Host "    Get-VMNetworkAdapter -VMName $VMName | Select -Expand IPAddresses" -ForegroundColor White
Write-Host "Then SSH in:" -ForegroundColor Yellow
Write-Host "    ssh vmbuildadmin@<that-ip>   # key from Get-LinuxAdminSshKeyPair" -ForegroundColor White
