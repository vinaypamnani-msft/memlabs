<#
.SYNOPSIS
    Type text/keys into a Hyper-V VM console via the Msvm_Keyboard WMI class.

.DESCRIPTION
    Hyper-V's vmconnect has no clipboard paste for Linux guests.
    This script uses the host-side Msvm_Keyboard.TypeText / TypeKey methods to
    inject keystrokes straight into the VM's virtual keyboard - works on any
    guest OS (Linux, Windows, BIOS prompts, etc.) regardless of integration
    services or Enhanced Session.

    Usage prerequisites:
      - Run from an elevated PowerShell on the Hyper-V host.
      - The VM must be running.
      - vmconnect should be open and the guest TTY where you want input
        must be the focused window inside the VM (the keyboard injects
        wherever the guest's keyboard focus currently is - same as if you
        typed on a real attached keyboard).

.EXAMPLE
    .\Send-VMText.ps1 -VMName CON-LINUXCLIENT1 -Recover
        Runs the canned LinuxClient DHCP recovery (revive systemd-networkd).

.EXAMPLE
    .\Send-VMText.ps1 -VMName CON-LINUXCLIENT1 -Text 'whoami' -PressEnter
        Types 'whoami' then Enter.

.EXAMPLE
    Get-Content .\my-script.sh | .\Send-VMText.ps1 -VMName CON-LINUXCLIENT1 -PressEnter
        Pipes a file in line-by-line, pressing Enter after each.
#>
[CmdletBinding(DefaultParameterSetName = 'Text')]
param(
    [Parameter(Mandatory)]
    [string]$VMName,

    [Parameter(ParameterSetName = 'Text', ValueFromPipeline)]
    [string[]]$Text,

    [Parameter(ParameterSetName = 'Text')]
    [switch]$PressEnter,

    [Parameter(ParameterSetName = 'Recover')]
    [switch]$Recover,

    # Milliseconds between lines when piping multi-line input.
    [int]$LineDelayMs = 250
)

begin {
    $vm = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem `
                          -Filter "ElementName='$VMName'" -ErrorAction Stop
    if (-not $vm)            { throw "VM '$VMName' not found." }
    if ($vm.EnabledState -ne 2) { throw "VM '$VMName' is not running (EnabledState=$($vm.EnabledState))." }

    $kbd = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_Keyboard -ErrorAction Stop
    if (-not $kbd) { throw "Could not get Msvm_Keyboard for '$VMName'." }

    # Common Windows virtual-key codes
    $VK = @{
        Enter     = [uint16]0x0D
        Tab       = [uint16]0x09
        Esc       = [uint16]0x1B
        Backspace = [uint16]0x08
    }

    function Send-Line {
        param([string]$Line, [switch]$NoEnter)
        # TypeText is ASCII only; strip CR, keep printable. Multi-line strings
        # should be sent line-by-line - the Enter key is sent separately.
        $clean = ($Line -replace "`r", '')
        if ($clean.Length -gt 0) {
            $null = Invoke-CimMethod -InputObject $kbd -MethodName TypeText `
                                     -Arguments @{ asciiText = $clean }
        }
        if (-not $NoEnter) {
            $null = Invoke-CimMethod -InputObject $kbd -MethodName TypeKey `
                                     -Arguments @{ keyCode = $VK.Enter }
        }
        Start-Sleep -Milliseconds $LineDelayMs
    }

    if ($Recover) {
        Write-Host "Sending DHCP-recovery commands to $VMName ..." -ForegroundColor Cyan
        Write-Host "  (make sure you've logged into the console first; commands will run as the focused user via sudo)" -ForegroundColor DarkGray

        # Heredoc-based recipe: revives systemd-networkd (Ubuntu 24.04 has no
        # dhclient anymore) and writes a wildcard DHCP profile that matches
        # both eth* (Hyper-V legacy) and en* (predictable names).
        $recipe = @(
            "sudo systemctl unmask systemd-networkd",
            "sudo mkdir -p /etc/systemd/network",
            "sudo tee /etc/systemd/network/10-memlabs-dhcp.network >/dev/null <<'EOF'",
            "[Match]",
            "Name=eth* en*",
            "",
            "[Network]",
            "DHCP=yes",
            "EOF",
            # Make sure netplan / NM aren't fighting us.
            "sudo rm -f /etc/cloud/cloud.cfg.d/99-network-renderer.cfg",
            "sudo systemctl enable --now systemd-networkd",
            "sudo systemctl restart systemd-networkd",
            "sleep 5",
            "ip -4 addr show",
            "ip route"
        )

        foreach ($line in $recipe) { Send-Line -Line $line }

        Write-Host "Done. Check the VM console for 'inet 192.168.x.y' under eth0/en* in the 'ip -4 addr show' output." -ForegroundColor Green
        Write-Host "Once it has an IP, ssh from the host so you get real clipboard:" -ForegroundColor Yellow
        Write-Host "    ssh vmbuildadmin@<that-ip>   # key under `$env:USERPROFILE\.ssh\memlabs*" -ForegroundColor Yellow
        return
    }
}

process {
    if ($PSCmdlet.ParameterSetName -ne 'Text') { return }
    if ($null -eq $Text) { return }

    foreach ($block in $Text) {
        # Split on newlines so each line becomes a separate keystroke run.
        $lines = $block -split "`r?`n"
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $isLast = ($i -eq $lines.Count - 1)
            if ($isLast -and -not $PressEnter) {
                Send-Line -Line $lines[$i] -NoEnter
            } else {
                Send-Line -Line $lines[$i]
            }
        }
    }
}
