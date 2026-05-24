# Common.Linux.ps1
# Building blocks for Linux (Ubuntu) VMs in memlabs.
#
# Exports:
#   Get-LinuxAdminSshKeyPair  - cached host-side ed25519 keypair used to SSH
#                               into every memlabs Linux VM as vmbuildadmin
#   Get-OscdimgPath           - locate oscdimg.exe (Windows ADK) used to build
#                               the cloud-init NoCloud seed ISO
#   New-LinuxSeedIso          - generate a per-VM cloud-init seed ISO containing
#                               meta-data + user-data with the host SSH key
#                               authorized for vmbuildadmin
#   New-LinuxVirtualMachine   - create a Gen2 Hyper-V VM from the Ubuntu base
#                               VHDX with the seed ISO attached as DVD
#
# Higher-level orchestration (calling these from the create-VM scriptblock,
# DNS registration, RDCMan exclusion, etc.) lives in Phase 1d-1g.

function Get-LinuxAdminSshKeyPair {
    [CmdletBinding()]
    param (
        [switch]$ForceNew
    )

    $sshDir = Join-Path $Common.CachePath "ssh"
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }
    $privateKeyPath = Join-Path $sshDir "memlabs_ed25519"
    $publicKeyPath = "$privateKeyPath.pub"

    if ($ForceNew.IsPresent -or -not (Test-Path $privateKeyPath) -or -not (Test-Path $publicKeyPath)) {
        Write-Log "Generating ed25519 SSH keypair for memlabs Linux VMs at $privateKeyPath"
        if (Test-Path $privateKeyPath) { Remove-Item $privateKeyPath -Force }
        if (Test-Path $publicKeyPath) { Remove-Item $publicKeyPath -Force }

        $sshKeygen = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
        if (-not $sshKeygen) {
            $fallback = Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe"
            if (Test-Path $fallback) {
                $sshKeygen = [pscustomobject]@{ Source = $fallback }
            }
        }
        if (-not $sshKeygen) {
            throw "ssh-keygen.exe not found. Install the Windows OpenSSH client (Settings > Apps > Optional features > OpenSSH Client)."
        }

        # PowerShell mangles bare "" args for native exes (varies by version);
        # invoke through cmd.exe so the empty passphrase is passed literally.
        $quotedExe = '"' + $sshKeygen.Source + '"'
        $quotedKey = '"' + $privateKeyPath + '"'
        $cmdLine = "$quotedExe -t ed25519 -f $quotedKey -N `"`" -C memlabs-host@$env:COMPUTERNAME -q"
        $null = & cmd.exe /c $cmdLine
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $publicKeyPath)) {
            throw "ssh-keygen failed (exit=$LASTEXITCODE) building $privateKeyPath"
        }
    }

    return [pscustomobject]@{
        PrivateKeyPath = $privateKeyPath
        PublicKeyPath  = $publicKeyPath
        PublicKey      = (Get-Content $publicKeyPath -Raw).Trim()
    }
}

function Get-OscdimgPath {
    [CmdletBinding()]
    param ()

    $candidates = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\x86\Oscdimg\oscdimg.exe",
        (Join-Path $Common.AzureToolsPath "oscdimg\oscdimg.exe")
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path $p -PathType Leaf)) { return $p }
    }
    $onPath = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    return $null
}

function New-LinuxSeedIso {
    <#
    .SYNOPSIS
        Build a cloud-init NoCloud seed ISO for a memlabs Linux VM.

    .DESCRIPTION
        Generates meta-data + user-data files configuring:
          - hostname/fqdn
          - vmbuildadmin user with sudo NOPASSWD and the memlabs host ed25519
            public key authorized for SSH (no password login)
          - openssh-server + qemu-guest-agent installed and enabled
          - first-boot reboot after cloud-init applies

        Packages the files into an ISO with volume label `cidata` so the NoCloud
        datasource auto-detects them on first boot.

    .OUTPUTS
        Path to the produced ISO file.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [string]$Domain,

        [Parameter(Mandatory = $true)]
        [string]$OutputIsoPath,

        [Parameter(Mandatory = $false)]
        [string[]]$ExtraPackages = @(),

        [Parameter(Mandatory = $false)]
        [string[]]$ExtraRunCmd = @()
    )

    $oscdimg = Get-OscdimgPath
    if (-not $oscdimg) {
        throw "oscdimg.exe not found. Install the Windows ADK Deployment Tools, or drop oscdimg.exe (+ its DLLs) at $(Join-Path $Common.AzureToolsPath 'oscdimg\oscdimg.exe')."
    }

    $sshKey = Get-LinuxAdminSshKeyPair
    $instanceId = "memlabs-$VmName-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
    $fqdn = "$VmName.$Domain".ToLower()

    $packages = @('openssh-server', 'qemu-guest-agent') + $ExtraPackages | Select-Object -Unique
    $packagesYaml = ($packages | ForEach-Object { "  - $_" }) -join "`n"

    $runcmd = @(
        'systemctl enable --now qemu-guest-agent || true',
        'systemctl enable --now ssh || true',
        'ufw allow OpenSSH || true'
    ) + $ExtraRunCmd
    $runcmdYaml = ($runcmd | ForEach-Object { "  - $_" }) -join "`n"

    # meta-data: NoCloud requires instance-id; local-hostname is a fallback.
    $metaData = @"
instance-id: $instanceId
local-hostname: $($VmName.ToLower())
"@

    # user-data: '#cloud-config' header is mandatory.
    $userData = @"
#cloud-config
hostname: $($VmName.ToLower())
fqdn: $fqdn
manage_etc_hosts: true
preserve_hostname: false

users:
  - name: vmbuildadmin
    gecos: memlabs admin
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - $($sshKey.PublicKey)

ssh_pwauth: false
disable_root: true

package_update: true
package_upgrade: false
packages:
$packagesYaml

runcmd:
$runcmdYaml

power_state:
  mode: reboot
  delay: now
  message: cloud-init complete, rebooting
  condition: true
"@

    # Stage files in a per-VM scratch dir under the host TempPath.
    $stage = Join-Path $Common.TempPath "cloudinit\$VmName"
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    # cloud-init expects LF line endings; .NET WriteAllText defaults to whatever
    # was in the string. Force LF by replacing CRLF before write.
    [System.IO.File]::WriteAllText((Join-Path $stage "meta-data"), ($metaData -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $stage "user-data"), ($userData -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))

    # Ensure output dir exists.
    $outDir = Split-Path -Parent $OutputIsoPath
    if ($outDir -and -not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    if (Test-Path $OutputIsoPath) { Remove-Item $OutputIsoPath -Force }

    # Build the ISO. -lcidata sets the volume label NoCloud looks for.
    # -j2 = Joliet + ISO9660 (cloud-init reads either); -m = ignore max size;
    # -n = allow long filenames.
    $oscdimgArgs = @('-j2', '-lcidata', '-m', '-n', $stage, $OutputIsoPath)
    & $oscdimg @oscdimgArgs | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $OutputIsoPath)) {
        throw "oscdimg failed (exit=$LASTEXITCODE) building $OutputIsoPath from $stage"
    }

    Write-Log "Built cloud-init seed ISO for $VmName at $OutputIsoPath"
    return $OutputIsoPath
}

function New-LinuxVirtualMachine {
    <#
    .SYNOPSIS
        Create a Gen2 Hyper-V VM from the Ubuntu cloud base VHDX with a
        cloud-init seed ISO attached as DVD.

    .DESCRIPTION
        Tailored for Ubuntu cloud images: Gen2 firmware, Secure Boot disabled
        (cloud image's shim doesn't always pair cleanly with Hyper-V's UEFI
        templates in lab scenarios), SCSI disk, dynamic memory, qemu-guest-agent
        integration via the cloud-init seed.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [string]$VmPath,

        [Parameter(Mandatory = $true)]
        [string]$SourceDiskPath,

        [Parameter(Mandatory = $true)]
        [string]$Memory,

        [Parameter(Mandatory = $false)]
        [string]$dynamicMinRam,

        [Parameter(Mandatory = $true)]
        [int]$Processors,

        [Parameter(Mandatory = $true)]
        [string]$SwitchName,

        [Parameter(Mandatory = $true)]
        [string]$Domain,

        [Parameter(Mandatory = $false)]
        [PsCustomObject]$DeployConfig,

        [Parameter(Mandatory = $false)]
        [switch]$ForceNew,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $oldProgress = $Global:ProgressPreference
    $Global:ProgressPreference = 'SilentlyContinue'
    try {
        if ($WhatIf) {
            Write-Log "WhatIf: would create Linux VM $VmName in $VmPath from $SourceDiskPath ($Memory, $Processors vCPU, switch $SwitchName)"
            return $true
        }

        if (-not (Test-Path $SourceDiskPath)) {
            Write-Log "$VmName`: Source VHDX $SourceDiskPath not found. Run baseimagestaging\New-LinuxBaseImage.ps1 first." -Failure -OutputStream
            return $false
        }

        $existing = Get-VM -Name $VmName -ErrorAction SilentlyContinue
        if ($existing -and -not $ForceNew.IsPresent) {
            Write-Log "$VmName`: Linux VM already exists and -ForceNew not specified." -Failure
            return $false
        }
        if ($existing -and $ForceNew.IsPresent) {
            if ($existing.State -ne 'Off') {
                $existing | Stop-VM -TurnOff -Force -WarningAction SilentlyContinue
            }
            $existing | Remove-VM -Force
            if (Test-Path $existing.Path) {
                Remove-Item -Path $existing.Path -Force -Recurse -ErrorAction SilentlyContinue
            }
            Get-List -FlushCache | Out-Null
        }

        $vmSubPath = Join-Path $VmPath $VmName
        if (Test-Path $vmSubPath) {
            Remove-Item -Path $vmSubPath -Force -Recurse -ErrorAction SilentlyContinue
        }

        Write-Log "$VmName`: Creating Gen2 Linux VM"
        $vm = New-VM -Name $VmName -Path $VmPath -Generation 2 `
            -MemoryStartupBytes ($Memory / 1) -SwitchName $SwitchName -ErrorAction Stop

        # Dynamic memory mirror of New-VirtualMachine, simpler defaults.
        if ($dynamicMinRam -and ($dynamicMinRam / 1) -gt 40MB -and ($dynamicMinRam / 1) -lt ($Memory / 1)) {
            $vm | Set-VMMemory -DynamicMemoryEnabled $true `
                -MinimumBytes ($dynamicMinRam / 1) `
                -MaximumBytes ($Memory / 1) `
                -StartupBytes ($Memory / 1) -ErrorAction Stop
        }

        if ($DeployConfig) {
            New-VmNote -VmName $VmName -DeployConfig $DeployConfig -InProgress $true
        }

        # Copy the base VHDX to the VM dir as its OS disk.
        $osDiskName = "$($VmName)_OS.vhdx"
        $osDiskPath = Join-Path $vm.Path $osDiskName
        $worked = Get-File -Source $SourceDiskPath -Destination $osDiskPath `
            -DisplayName "Copying Linux base image to $osDiskPath" -Action "Copying"
        if (-not $worked) {
            Write-Log "$VmName`: Failed to copy $SourceDiskPath -> $osDiskPath." -Failure
            return $false
        }

        Enable-VMIntegrationService -VMName $VmName -Name "Guest Service Interface" -ErrorAction SilentlyContinue | Out-Null

        # Disable Secure Boot. Ubuntu cloud images do ship a Microsoft-signed
        # shim and work under -SecureBootTemplate "MicrosoftUEFICertificateAuthority",
        # but disabling SB is universally compatible and matches typical lab usage.
        Set-VMFirmware -VMName $VmName -EnableSecureBoot Off

        Set-VM -Name $VmName -AutomaticStopAction Save -ProcessorCount $Processors | Out-Null

        Add-VMHardDiskDrive -VMName $VmName -Path $osDiskPath -ControllerType SCSI -ControllerNumber 0 | Out-Null

        # Build and attach the cloud-init seed ISO.
        $seedIsoPath = Join-Path $vm.Path "$VmName-seed.iso"
        $null = New-LinuxSeedIso -VmName $VmName -Domain $Domain -OutputIsoPath $seedIsoPath
        Add-VMDvdDrive -VMName $VmName -Path $seedIsoPath | Out-Null

        # Boot order: hard disk first, DVD (seed) as fallback. NoCloud
        # datasource reads the DVD regardless of boot order, so this is
        # purely about not trying to PXE if the VHDX is healthy.
        $firmware = Get-VMFirmware -VMName $VmName
        $hd = $firmware.BootOrder | Where-Object { $_.Device -is [Microsoft.HyperV.PowerShell.HardDiskDrive] }
        $dvd = $firmware.BootOrder | Where-Object { $_.Device -is [Microsoft.HyperV.PowerShell.DvdDrive] }
        $net = $firmware.BootOrder | Where-Object { $_.BootType -eq 'Network' }
        if ($hd) {
            $newOrder = @($hd, $dvd, $net) | Where-Object { $_ }
            Set-VMFirmware -VMName $VmName -BootOrder $newOrder | Out-Null
        }

        Write-Log "$VmName`: Starting Linux VM (cloud-init will run on first boot, then reboot)"
        $started = Start-VM2 -Name $VmName -Passthru
        if (-not $started) {
            Write-Log "$VmName`: Failed to start." -Failure
            return $false
        }

        return $true
    }
    catch {
        Write-Log "$VmName`: New-LinuxVirtualMachine exception: $_" -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        return $false
    }
    finally {
        $Global:ProgressPreference = $oldProgress
    }
}
