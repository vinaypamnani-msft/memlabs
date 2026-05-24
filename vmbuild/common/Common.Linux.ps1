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

function New-NoCloudSeedIsoWithImapi {
    <#
    .SYNOPSIS
        Build a NoCloud seed ISO using IMAPI2FS (built into Windows since
        Vista) so we don't depend on oscdimg.exe from the Windows ADK.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$OutputIsoPath,
        [Parameter(Mandatory = $false)][string]$VolumeLabel = 'cidata'
    )

    # IStream -> file helper (canonical pattern from New-IsoFile).
    if (-not ('MemlabsIsoFile' -as [type])) {
        Add-Type -CompilerOptions '/unsafe' -TypeDefinition @'
public class MemlabsIsoFile {
    public unsafe static void Create(string path, object stream, int blockSize, int totalBlocks) {
        int bytes = 0;
        byte[] buf = new byte[blockSize];
        var ptr = (System.IntPtr)(&bytes);
        var o = System.IO.File.OpenWrite(path);
        var i = stream as System.Runtime.InteropServices.ComTypes.IStream;
        if (o != null) {
            while (totalBlocks-- > 0) { i.Read(buf, blockSize, ptr); o.Write(buf, 0, bytes); }
            o.Flush(); o.Close();
        }
    }
}
'@
    }

    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    try {
        $fsi.FileSystemsToCreate = 3   # ISO9660 (1) | Joliet (2)
        $fsi.VolumeName = $VolumeLabel
        $fsi.Root.AddTree($SourceDir, $false)
        $result = $fsi.CreateResultImage()
        [MemlabsIsoFile]::Create($OutputIsoPath, $result.ImageStream, $result.BlockSize, $result.TotalBlocks)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($fsi) | Out-Null
    }
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

    # oscdimg is preferred when available (faster, more deterministic), but
    # we fall back to IMAPI2FS so the build doesn't require the Windows ADK.
    $oscdimg = Get-OscdimgPath

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

    if ($oscdimg) {
        # Build the ISO. -lcidata sets the volume label NoCloud looks for.
        # -j2 = Joliet + ISO9660 (cloud-init reads either); -m = ignore max size;
        # -n = allow long filenames.
        $oscdimgArgs = @('-j2', '-lcidata', '-m', '-n', $stage, $OutputIsoPath)
        & $oscdimg @oscdimgArgs | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $OutputIsoPath)) {
            throw "oscdimg failed (exit=$LASTEXITCODE) building $OutputIsoPath from $stage"
        }
    }
    else {
        Write-Log "oscdimg.exe not found; building NoCloud seed ISO via IMAPI2FS for $VmName."
        New-NoCloudSeedIsoWithImapi -SourceDir $stage -OutputIsoPath $OutputIsoPath -VolumeLabel 'cidata'
        if (-not (Test-Path $OutputIsoPath)) {
            throw "IMAPI2FS ISO build failed for $OutputIsoPath"
        }
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

function Get-LinuxSshExePath {
    [CmdletBinding()]
    param ()
    $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if ($ssh) { return $ssh.Source }
    $fallback = Join-Path $env:WINDIR "System32\OpenSSH\ssh.exe"
    if (Test-Path $fallback) { return $fallback }
    throw "ssh.exe not found. Install the Windows OpenSSH client (Settings > Apps > Optional features > OpenSSH Client)."
}

function Get-LinuxVmIPAddress {
    <#
    .SYNOPSIS
        Resolve a Linux Hyper-V VM's IPv4 address via Hyper-V KVP integration.

    .DESCRIPTION
        Ubuntu 24.04's hv_utils kernel module + linux-azure or linux-virtual
        userspace daemons publish guest IPs through the Hyper-V Data Exchange
        service. Get-VMNetworkAdapter surfaces this as the .IPAddresses array.
        Returns $null if no IPv4 is reported yet (VM still booting / running
        cloud-init / awaiting DHCP).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    $adapters = Get-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue
    if (-not $adapters) { return $null }

    foreach ($a in $adapters) {
        foreach ($ip in $a.IPAddresses) {
            if ($ip -and $ip -notmatch ':' -and $ip -notmatch '^169\.254\.') {
                return $ip
            }
        }
    }
    return $null
}

function Wait-LinuxVmReady {
    <#
    .SYNOPSIS
        Block until a Linux VM is reachable over SSH as vmbuildadmin.

    .DESCRIPTION
        Polls for a usable IPv4 from Hyper-V KVP, then attempts a no-op SSH
        login (`true`) with the cached host key. First-boot pipeline:
        cloud-init applies user-data, installs openssh-server, reboots, then
        SSH comes up. Default TimeoutSeconds=900 (15 min) accommodates the
        first-boot apt install on a new VM.

    .OUTPUTS
        IPv4 string on success; $null on timeout.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 900,

        [Parameter(Mandatory = $false)]
        [int]$PollIntervalSeconds = 10
    )

    $sshExe = Get-LinuxSshExePath
    $keyPair = Get-LinuxAdminSshKeyPair
    $knownHostsPath = Join-Path (Split-Path $keyPair.PrivateKeyPath) "known_hosts"

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $startedAt = Get-Date
    Write-Log "$VmName`: Waiting for Linux VM to become SSH-ready (timeout ${TimeoutSeconds}s)"
    write-progress2 "Wait for Linux VM" -Status "$VmName`: cloud-init running, waiting for IP..." -force

    $lastReportedIp = $null
    while ((Get-Date) -lt $deadline) {
        $elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
        $ip = Get-LinuxVmIPAddress -VmName $VmName
        if ($ip) {
            if ($ip -ne $lastReportedIp) {
                write-progress2 "Wait for Linux VM" -Status "$VmName`: got IP $ip, probing SSH (elapsed ${elapsed}s / ${TimeoutSeconds}s)" -force
                $lastReportedIp = $ip
            }
            $sshArgs = @(
                '-i', $keyPair.PrivateKeyPath,
                '-o', 'StrictHostKeyChecking=accept-new',
                '-o', "UserKnownHostsFile=$knownHostsPath",
                '-o', 'BatchMode=yes',
                '-o', 'ConnectTimeout=5',
                '-o', 'LogLevel=ERROR',
                "vmbuildadmin@$ip",
                'true'
            )
            $null = & $sshExe @sshArgs 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Log "$VmName`: SSH ready at $ip" -LogOnly
                write-progress2 "Wait for Linux VM" -Status "$VmName`: SSH ready at $ip" -force -Completed
                return $ip
            }
        }
        else {
            write-progress2 "Wait for Linux VM" -Status "$VmName`: waiting for cloud-init / DHCP (elapsed ${elapsed}s / ${TimeoutSeconds}s)" -force
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }

    Write-Log "$VmName`: Timeout waiting for Linux VM SSH readiness (${TimeoutSeconds}s)" -Failure
    write-progress2 "Wait for Linux VM" -Status "$VmName`: SSH-ready timeout after ${TimeoutSeconds}s" -force -Completed
    return $null
}

function Invoke-LinuxVmCommand {
    <#
    .SYNOPSIS
        Run a bash command on a memlabs Linux VM over SSH as vmbuildadmin.

    .DESCRIPTION
        SSH analog of Invoke-VmCommand for Linux guests. Resolves the VM's
        IPv4 via Hyper-V KVP (or accepts -IPAddress explicitly), connects with
        the cached ed25519 keypair, runs the supplied bash command, and
        returns an object shaped like Invoke-VmCommand's result:

            CommandResult     [bool]   $true if exit code == 0
            ScriptBlockFailed [bool]   $true on SSH or command failure
            ScriptBlockOutput [string] combined stdout (stderr appended on failure)
            ExitCode          [int]    raw ssh/remote exit code

        Use -Sudo to wrap the command in `sudo -n` (passwordless sudo is
        configured by the cloud-init user-data).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [string]$BashCommand,

        [Parameter(Mandatory = $false)]
        [string]$IPAddress,

        [Parameter(Mandatory = $false)]
        [string]$DisplayName,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 180,

        [Parameter(Mandatory = $false)]
        [switch]$Sudo,

        [Parameter(Mandatory = $false)]
        [switch]$SuppressLog,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    if (-not $DisplayName) {
        $DisplayName = if ($BashCommand.Length -gt 80) { $BashCommand.Substring(0, 77) + '...' } else { $BashCommand }
    }

    $return = [pscustomobject]@{
        CommandResult     = $false
        ScriptBlockFailed = $false
        ScriptBlockOutput = $null
        ExitCode          = -1
    }

    if ($WhatIf.IsPresent) {
        Write-Log "WhatIf: Would run '$DisplayName' on Linux VM $VmName"
        $return.CommandResult = $true
        return $return
    }

    if (-not $IPAddress) {
        $IPAddress = Get-LinuxVmIPAddress -VmName $VmName
    }
    if (-not $IPAddress) {
        if (-not $SuppressLog) {
            Write-Log "$VmName`: Cannot resolve IPv4 (Hyper-V KVP not reporting). Skip '$DisplayName'." -Failure
        }
        $return.ScriptBlockFailed = $true
        return $return
    }

    if (-not $SuppressLog) {
        Write-Log "$VmName`: Running '$DisplayName' (ssh $IPAddress)" -Verbose
    }

    $sshExe = Get-LinuxSshExePath
    $keyPair = Get-LinuxAdminSshKeyPair
    $knownHostsPath = Join-Path (Split-Path $keyPair.PrivateKeyPath) "known_hosts"

    # Pipe the command in via stdin to avoid Windows command-line quoting
    # mismatches; remote `bash -s` reads the entire script from stdin.
    $remoteShell = if ($Sudo.IsPresent) { 'sudo -n bash -s' } else { 'bash -s' }

    $sshArgs = @(
        '-i', $keyPair.PrivateKeyPath,
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', "UserKnownHostsFile=$knownHostsPath",
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=10',
        '-o', "ServerAliveInterval=$([Math]::Max(15, [int]($TimeoutSeconds / 4)))",
        '-o', 'LogLevel=ERROR',
        "vmbuildadmin@$IPAddress",
        $remoteShell
    )

    try {
        # Build a quoted argument string. ProcessStartInfo.ArgumentList isn't
        # available in PS 5.1, so escape manually: any arg containing whitespace
        # or quotes gets wrapped in double quotes with internal quotes doubled.
        $quotedArgs = foreach ($a in $sshArgs) {
            if ($a -match '[\s"]') {
                '"' + ($a -replace '"', '""') + '"'
            }
            else {
                $a
            }
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $sshExe
        $psi.Arguments = ($quotedArgs -join ' ')
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($psi)

        # Async drains so we don't deadlock on a full pipe buffer.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $proc.StandardInput.Write($BashCommand)
        $proc.StandardInput.Close()

        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch { }
            if (-not $SuppressLog) {
                Write-Log "$VmName`: SSH command '$DisplayName' timed out after ${TimeoutSeconds}s" -Failure
            }
            $return.ScriptBlockFailed = $true
            $return.ScriptBlockOutput = "TIMEOUT after ${TimeoutSeconds}s"
            return $return
        }

        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $return.ExitCode = $proc.ExitCode

        if ($proc.ExitCode -eq 0) {
            $return.CommandResult = $true
            $return.ScriptBlockOutput = $stdout
        }
        else {
            $return.ScriptBlockFailed = $true
            $combined = $stdout
            if ($stderr) {
                if ($combined) { $combined += "`n" }
                $combined += $stderr
            }
            $return.ScriptBlockOutput = $combined
            if (-not $SuppressLog) {
                $excerpt = if ($combined) { ($combined -replace "`r`n", "`n").Trim() } else { '(no output)' }
                if ($excerpt.Length -gt 400) { $excerpt = $excerpt.Substring(0, 400) + '...' }
                Write-Log "$VmName`: '$DisplayName' failed (exit=$($proc.ExitCode)): $excerpt" -Failure
            }
        }
    }
    catch {
        $return.ScriptBlockFailed = $true
        $return.ScriptBlockOutput = "$_"
        if (-not $SuppressLog) {
            Write-Log "$VmName`: Exception running '$DisplayName': $_" -Failure
            Write-Log "$($_.ScriptStackTrace)" -LogOnly
        }
    }

    return $return
}


function Register-LinuxVmDns {
    <#
    .SYNOPSIS
        Create / refresh an A record (and PTR) on the domain DC for a Linux VM.

    .DESCRIPTION
        Linux VMs are not domain-joined and do not register themselves with
        AD-integrated DNS the way Windows clients do via secure dynamic update.
        This calls the DC over PSDirect (Invoke-VmCommand) to add an A record
        for <VmName>.<Domain> -> <IPAddress>, creating the PTR if the reverse
        lookup zone exists. Idempotent: deletes any existing A record for the
        same node first so re-runs after a DHCP lease change are safe.

    .OUTPUTS
        $true on success, $false on failure.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [string]$Domain,

        [Parameter(Mandatory = $true)]
        [string]$DCName,

        [Parameter(Mandatory = $true)]
        [string]$IPAddress
    )

    $scriptBlock = {
        $node = $using:VmName
        $zone = $using:Domain
        $ip   = $using:IPAddress

        $existing = Get-DnsServerResourceRecord -ZoneName $zone -Node $node -RRType A -ErrorAction SilentlyContinue
        if ($existing) {
            foreach ($r in $existing) {
                Remove-DnsServerResourceRecord -ZoneName $zone -InputObject $r -Force -ErrorAction SilentlyContinue
            }
        }

        Add-DnsServerResourceRecordA -ZoneName $zone -Name $node -IPv4Address $ip -CreatePtr -AllowUpdateAny -ErrorAction Stop
        return $true
    }

    $result = Invoke-VmCommand -VmName $DCName -VmDomainName $Domain -ScriptBlock $scriptBlock -DisplayName "Register DNS A: $VmName -> $IPAddress" -CommandReturnsBool
    if ($result.ScriptBlockFailed -or -not $result.CommandResult) {
        Write-Log "$VmName`: Failed to register DNS A record on $DCName ($Domain -> $IPAddress)" -Failure
        return $false
    }
    Write-Log "$VmName`: Registered DNS A record $VmName.$Domain -> $IPAddress on $DCName"
    return $true
}


function Test-VmIsLinux {
    <#
    .SYNOPSIS
        Return $true if a VM object (from $deployConfig.virtualMachines or
        Get-List) represents a memlabs Linux VM.

    .DESCRIPTION
        Recognises either the explicit osFamily=Linux property (set by the
        Phase 1g schema work) or, as a fallback for VMs loaded before that
        property was added, an operatingSystem/deployedOS value matching
        Ubuntu*. Safe to call on $null (returns $false).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, ValueFromPipeline = $true)]
        [object]$Vm
    )

    if (-not $Vm) { return $false }

    if ($Vm.PSObject.Properties.Name -contains 'osFamily' -and $Vm.osFamily -eq 'Linux') {
        return $true
    }

    foreach ($prop in @('operatingSystem', 'deployedOS')) {
        if ($Vm.PSObject.Properties.Name -contains $prop) {
            $val = $Vm.$prop
            if ($val -and ($val -like 'Ubuntu*' -or $val -like 'Debian*' -or $val -like 'Linux*')) {
                return $true
            }
        }
    }
    return $false
}


function Install-LinuxProxyServer {
    <#
    .SYNOPSIS
        Install and configure Squid forward proxy on a Linux Proxy VM.

    .DESCRIPTION
        Idempotently installs squid + ufw via apt, writes a minimal
        /etc/squid/squid.conf that listens on :3128 and ACLs the lab
        network(s) discovered from deployConfig.vmOptions.network plus
        any additional subnets used by other VMs in the config, enables
        and (re)starts the service, opens 3128/tcp in ufw if active, and
        records lastPhaseComplete=2 in the VM note so re-runs are quick.

        Driven over SSH by Invoke-LinuxVmCommand. Safe to call multiple
        times (apt-get is idempotent; squid.conf is rewritten each run;
        ufw rule re-add is a no-op).

    .PARAMETER deployConfig
        The deployment config (used to find subnets and the Proxy VM).

    .PARAMETER ProxyVM
        Optional. The Proxy VM object. If omitted, the first VM in
        deployConfig.virtualMachines with role=Proxy is used.

    .OUTPUTS
        [bool] $true on success, $false on any failure (logged).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$deployConfig,
        [Parameter(Mandatory = $false)]
        [object]$ProxyVM
    )

    if (-not $ProxyVM) {
        $ProxyVM = $deployConfig.virtualMachines | Where-Object { $_.role -eq 'Proxy' } | Select-Object -First 1
    }
    if (-not $ProxyVM) {
        Write-Log "Install-LinuxProxyServer: no Proxy VM found in config; skipping" -LogOnly
        return $true
    }

    $vmName = $ProxyVM.vmName
    Write-Log "[Proxy] $vmName`: Installing Squid forward proxy"

    # Make sure the VM is up and SSH-reachable before doing anything.
    $ip = Wait-LinuxVmReady -VmName $vmName -TimeoutSeconds 900
    if (-not $ip) {
        Write-Log "[Proxy] $vmName`: VM not reachable over SSH; cannot install Squid" -Failure
        return $false
    }

    # Build ACL list: every subnet referenced by any non-hidden VM in this
    # config, plus the default vmOptions.network if set. We emit /24 ACLs
    # because all memlabs networks are /24.
    $subnets = New-Object System.Collections.Generic.HashSet[string]
    if ($deployConfig.vmOptions.network) {
        [void]$subnets.Add($deployConfig.vmOptions.network)
    }
    foreach ($vm in $deployConfig.virtualMachines) {
        if ($vm.network) { [void]$subnets.Add($vm.network) }
    }
    $aclLines = @()
    $i = 0
    foreach ($s in $subnets) {
        # Normalize: memlabs stores "192.168.1.0" already, but be defensive.
        $base = $s
        if ($base -notmatch '/\d+$') { $base = "$base/24" }
        $aclLines += "acl memlabs_net$i src $base"
        $i++
    }
    $aclNames = (0..($i - 1) | ForEach-Object { "memlabs_net$_" }) -join ' '

    $squidConf = @"
# memlabs Squid forward proxy
# Managed by Install-LinuxProxyServer -- changes will be overwritten.

http_port 3128

$($aclLines -join "`n")

http_access allow $aclNames
http_access allow localhost
http_access deny all

# Disable disk cache; lab proxy is for outbound NAT control, not perf.
cache deny all

# Keep memory cache small (default 256MB is excessive for 1GB VM).
cache_mem 64 MB

# Honour client UA / forwarded-for for diagnostics; this is a lab.
forwarded_for on
via off

# Standard ports allowed via CONNECT (HTTPS, etc.)
acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 21
acl Safe_ports port 443
acl Safe_ports port 70
acl Safe_ports port 210
acl Safe_ports port 1025-65535
acl Safe_ports port 280
acl Safe_ports port 488
acl Safe_ports port 591
acl Safe_ports port 777
acl CONNECT method CONNECT

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports

coredump_dir /var/spool/squid
"@

    # Base64-encode the config so we can pipe it through bash without
    # quoting hell.
    $confBytes = [System.Text.Encoding]::UTF8.GetBytes($squidConf)
    $confB64 = [Convert]::ToBase64String($confBytes)

    $bash = @"
set -e
export DEBIAN_FRONTEND=noninteractive

# Wait for any background apt/unattended-upgrades to finish (cloud-init may
# still be running at this point on a freshly-provisioned VM).
for i in `$(seq 1 60); do
    if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && \
       ! fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
        break
    fi
    sleep 5
done

apt-get update -y
apt-get install -y squid ufw

install -d -m 0755 /etc/squid
echo '$confB64' | base64 -d > /etc/squid/squid.conf
chmod 0644 /etc/squid/squid.conf

systemctl enable squid
systemctl restart squid

# Open 3128 in ufw if the firewall is active; otherwise just stage the rule.
ufw allow 3128/tcp || true

# Quick self-test
ss -ltnp 'sport = :3128' | grep -q ':3128' || { echo 'squid not listening on 3128'; exit 1; }

echo PROXY_READY
"@

    $result = Invoke-LinuxVmCommand -VmName $vmName -BashCommand $bash -Sudo -TimeoutSeconds 600 -DisplayName "Install Squid"
    if ($result.ScriptBlockFailed -or $result.ExitCode -ne 0) {
        Write-Log "[Proxy] $vmName`: Squid install failed (ExitCode=$($result.ExitCode))`n$($result.ScriptBlockOutput)" -Failure
        return $false
    }
    if ($result.ScriptBlockOutput -notmatch 'PROXY_READY') {
        Write-Log "[Proxy] $vmName`: Squid install did not report ready`n$($result.ScriptBlockOutput)" -Failure
        return $false
    }

    Write-Log "[Proxy] $vmName`: Squid listening on ${ip}:3128 (ACLs: $($subnets -join ', '))"

    # Mark phase complete in VM note so subsequent re-runs can short-circuit
    # via the normal lastPhaseComplete check used by Windows VMs.
    try {
        New-VmNote -VmName $vmName -DeployConfig $deployConfig -Successful $true -Phase 2 | Out-Null
    }
    catch {
        Write-Log "[Proxy] $vmName`: Failed to update VM note: $_" -Warning
    }

    return $true
}


function Test-VmUsesProxy {
    <#
    .SYNOPSIS
        Return $true if a VM is opted into routing through the lab Squid proxy.

    .DESCRIPTION
        Honours the per-VM 'useProxy' boolean if present; otherwise falls back
        to deployConfig.domainDefaults.UseProxyForCM (for CM site-system roles)
        or UseProxyForClients (for everything else). Returns $false for the
        Proxy VM itself and for any Linux VM (proxy clients are Windows-only).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Vm,
        [Parameter(Mandatory = $false)]
        [object]$DeployConfig
    )

    if (-not $Vm) { return $false }
    # Hard exclusions: roles that must never route through the proxy.
    # Mirrors the exclusion list in Common.GenConfig.AddVM.ps1 so a
    # domainDefaults.UseProxyFor* setting on an existing/hidden VM
    # (which has no per-VM useProxy property) can't accidentally apply
    # client proxy + firewall enforcement to a DC, BDC, or offline root CA.
    $hardExclude = @('Proxy', 'DC', 'BDC', 'StandaloneRootCA')
    if ($Vm.role -in $hardExclude) { return $false }
    if (Test-VmIsLinux -Vm $Vm) { return $false }

    if ($Vm.PSObject.Properties.Name -contains 'useProxy') {
        return [bool]$Vm.useProxy
    }
    if ($DeployConfig -and $DeployConfig.domainDefaults) {
        $cmRoles = @('CAS', 'Primary', 'Secondary', 'SiteSystem', 'PassiveSite', 'WSUS', 'SQLAO', 'FileServer')
        $key = if ($Vm.role -in $cmRoles) { 'UseProxyForCM' } else { 'UseProxyForClients' }
        $val = $DeployConfig.domainDefaults.$key
        if ($null -ne $val) { return [bool]$val }
        # Legacy fallback: old configs may still have the single 'UseProxy' key.
        if ($null -ne $DeployConfig.domainDefaults.UseProxy) {
            return [bool]$DeployConfig.domainDefaults.UseProxy
        }
    }
    return $false
}


function Set-WindowsClientProxy {
    <#
    .SYNOPSIS
        Configure a Windows VM to route HTTP/HTTPS traffic through the lab
        Squid proxy.

    .DESCRIPTION
        Run remotely on the target VM via Invoke-VmCommand. Sets:
          - WinHTTP system proxy (netsh winhttp set proxy)
          - Machine-wide HTTP_PROXY/HTTPS_PROXY/NO_PROXY env vars
          - HKLM proxy policy for default-user profile fallback

        The proxy server is "<proxyFqdn>:3128" and the bypass list always
        includes <local>, the domain DNS suffix, and the domain subnet so
        intra-lab traffic never traverses Squid (which would just bounce
        back through host NAT).

        Idempotent. Safe to call repeatedly.

    .PARAMETER VmName
        Target Windows VM name (PSDirect-reachable).

    .PARAMETER Domain
        Active Directory domain (used for PSDirect creds + bypass list).

    .PARAMETER ProxyFqdn
        FQDN of the Linux Proxy VM (e.g. PROXY1.adatum.com).

    .PARAMETER BypassNetwork
        Optional. The /24 network base (e.g. 192.168.1.0). Added to bypass
        list as 192.168.1.* so intra-subnet traffic stays local.

    .OUTPUTS
        [bool] $true on success, $false on failure (logged).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [string]$VmName,
        [Parameter(Mandatory = $true)] [string]$Domain,
        [Parameter(Mandatory = $true)] [string]$ProxyFqdn,
        [Parameter(Mandatory = $false)] [string]$BypassNetwork
    )

    $proxyServer = "$ProxyFqdn`:3128"

    $bypassEntries = @('<local>', "*.$Domain", $ProxyFqdn)
    if ($BypassNetwork) {
        # Memlabs networks are /24 -> "192.168.1.*"
        $base = $BypassNetwork.TrimEnd('.0')
        if ($base -match '^(\d+\.\d+\.\d+)\.0$') { $base = $Matches[1] }
        elseif ($BypassNetwork -match '^(\d+\.\d+\.\d+)\.\d+$') { $base = $Matches[1] }
        $bypassEntries += "$base.*"
    }
    $bypassList = ($bypassEntries | Select-Object -Unique) -join ';'

    $scriptBlock = {
        param($proxyServer, $bypassList)
        $ErrorActionPreference = 'Stop'

        try {
            # 1) WinHTTP (used by BITS, Windows Update, .NET in some modes)
            & netsh winhttp set proxy proxy-server="$proxyServer" bypass-list="$bypassList" | Out-Null

            # 2) Machine-wide env vars (used by curl, PowerShell Invoke-WebRequest
            #    if -Proxy not specified, apt-style tooling, etc.)
            [Environment]::SetEnvironmentVariable('HTTP_PROXY', "http://$proxyServer", 'Machine')
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', "http://$proxyServer", 'Machine')
            [Environment]::SetEnvironmentVariable('NO_PROXY', $bypassList, 'Machine')

            # 3) HKLM proxy policy (applies to default user profile + any user
            #    whose HKCU doesn't override)
            $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'
            if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
            New-ItemProperty -Path $key -Name 'ProxySettingsPerUser' -PropertyType DWord -Value 0 -Force | Out-Null

            $ieKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
            New-ItemProperty -Path $ieKey -Name 'ProxyEnable' -PropertyType DWord -Value 1 -Force | Out-Null
            New-ItemProperty -Path $ieKey -Name 'ProxyServer' -PropertyType String -Value $proxyServer -Force | Out-Null
            New-ItemProperty -Path $ieKey -Name 'ProxyOverride' -PropertyType String -Value $bypassList -Force | Out-Null

            # Show resulting WinHTTP state for the log
            $current = & netsh winhttp show proxy
            return @{ Ok = $true; WinHttp = ($current -join "`n") }
        }
        catch {
            return @{ Ok = $false; Error = $_.ToString() }
        }
    }

    $result = Invoke-VmCommand -VmName $VmName -VmDomainName $Domain `
        -ScriptBlock $scriptBlock -ArgumentList $proxyServer, $bypassList `
        -DisplayName "Set proxy -> $proxyServer"
    if ($result.ScriptBlockFailed) {
        Write-Log "[Proxy] $VmName`: Set-WindowsClientProxy ScriptBlockFailed: $($result.ScriptBlockOutput)" -Failure
        return $false
    }
    $payload = $result.ScriptBlockOutput
    if (-not $payload -or -not $payload.Ok) {
        Write-Log "[Proxy] $VmName`: Set-WindowsClientProxy failed: $($payload.Error)" -Failure
        return $false
    }
    Write-Log "[Proxy] $VmName`: Routing via $proxyServer (bypass: $bypassList)"
    return $true
}


function Set-WindowsClientProxyForConfig {
    <#
    .SYNOPSIS
        Apply proxy client settings to every opted-in Windows VM in a deploy
        configuration.

    .DESCRIPTION
        Enumerates deployConfig.virtualMachines, filters via Test-VmUsesProxy,
        and calls Set-WindowsClientProxy for each. The proxy FQDN is built
        from the lone Proxy VM in the config; if no Proxy VM exists (and any
        VM has useProxy=true), logs a warning and returns.

        Designed to be invoked from Start-Phase after Phase 2 completes
        successfully, when domain-joined VMs are first reachable for config.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [object]$deployConfig
    )

    $proxyVm = $deployConfig.virtualMachines | Where-Object { $_.role -eq 'Proxy' } | Select-Object -First 1
    $clients = @($deployConfig.virtualMachines | Where-Object { Test-VmUsesProxy -Vm $_ -DeployConfig $deployConfig })

    if (-not $clients) { return $true }

    if (-not $proxyVm) {
        Write-Log "[Proxy] $($clients.Count) VM(s) have useProxy=true but no Proxy VM is in the config; skipping client config" -Warning
        return $false
    }

    $proxyFqdn = "$($proxyVm.vmName).$($deployConfig.vmOptions.domainName)"
    $bypassNet = $deployConfig.vmOptions.network

    $ok = $true
    foreach ($vm in $clients) {
        Write-Log "[Proxy] Configuring $($vm.vmName) -> $proxyFqdn`:3128"
        $r = Set-WindowsClientProxy -VmName $vm.vmName -Domain $deployConfig.vmOptions.domainName `
                -ProxyFqdn $proxyFqdn -BypassNetwork $bypassNet
        if (-not $r) { $ok = $false }
    }
    return $ok
}


