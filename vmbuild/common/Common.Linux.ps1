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
        [string[]]$ExtraRunCmd = @(),

        # When set, the VM gets a static IPv4 via cloud-init network-config
        # instead of DHCP. All three (StaticIPv4 / Gateway / Prefix) must be
        # provided together. Used to pin role-specific VMs (e.g. Proxy at .2)
        # to a deterministic address that lab clients can hard-code.
        [Parameter(Mandatory = $false)]
        [string]$StaticIPv4,

        [Parameter(Mandatory = $false)]
        [string]$Gateway,

        [Parameter(Mandatory = $false)]
        [int]$Prefix = 24
    )

    # oscdimg is preferred when available (faster, more deterministic), but
    # we fall back to IMAPI2FS so the build doesn't require the Windows ADK.
    $oscdimg = Get-OscdimgPath

    $sshKey = Get-LinuxAdminSshKeyPair
    $instanceId = "memlabs-$VmName-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
    $fqdn = "$VmName.$Domain".ToLower()

    # vmbuildadmin gets the same password as the Windows LocalAdmin so the user
    # can log in at the Hyper-V console (vmconnect) for diagnostics. SSH still
    # requires the key (ssh_pwauth stays false) so this isn't a remote-auth
    # downgrade.
    $consolePassword = $null
    if ($Common -and $Common.LocalAdmin) {
        try { $consolePassword = $Common.LocalAdmin.GetNetworkCredential().Password } catch { $consolePassword = $null }
    }
    if ($consolePassword) {
        $lockPasswdYaml = 'false'
        # YAML single-quote escape: ' -> ''
        $pwQuoted = "'" + ($consolePassword -replace "'", "''") + "'"
        $chpasswdBlock = @"

chpasswd:
  expire: false
  users:
    - name: vmbuildadmin
      password: $pwQuoted
      type: text
    - name: root
      password: $pwQuoted
      type: text
"@
    }
    else {
        $lockPasswdYaml = 'true'
        $chpasswdBlock = ''
    }

    # linux-tools-virtual / linux-cloud-tools-virtual provide hv_kvp_daemon and
    # hv_vss_daemon. Without them Get-VMNetworkAdapter.IPAddresses stays empty
    # on the host even after the guest has a working DHCP lease, and we have no
    # way to discover the VM's IP.
    $packages = @(
        'openssh-server',
        'qemu-guest-agent',
        'linux-tools-virtual',
        'linux-cloud-tools-virtual'
    ) + $ExtraPackages | Select-Object -Unique
    $packagesYaml = ($packages | ForEach-Object { "  - $_" }) -join "`n"

    $runcmd = @(
        'systemctl enable --now qemu-guest-agent || true',
        'systemctl enable --now ssh || true',
        'systemctl enable --now hv-kvp-daemon.service || true',
        'systemctl enable --now hv-vss-daemon.service || true',
        'ufw allow OpenSSH || true',
        # systemd-resolved consults FallbackDNS only when no DHCP/static DNS
        # answers. Restart so the dropin in write_files is picked up before
        # cloud-init's package_update tries to resolve archive.ubuntu.com.
        'systemctl restart systemd-resolved || true'
    ) + $ExtraRunCmd
    $runcmdYaml = ($runcmd | ForEach-Object { "  - $_" }) -join "`n"

    # meta-data: NoCloud requires instance-id; local-hostname is a fallback.
    $metaData = @"
instance-id: $instanceId
local-hostname: $($VmName.ToLower())
"@

    # network-config: NoCloud picks this up and writes /etc/netplan/50-cloud-init.yaml.
    # We use match: name "e*" so this applies to eth0 / enp* / ens* regardless of
    # how the kernel names the Hyper-V NIC. dhcp4-overrides.use-dns=false makes us
    # IGNORE the DNS servers DHCP advertises (which on a lab subnet is the domain
    # DC — fine for AD resolution but it can't resolve external names like
    # archive.ubuntu.com or bing.com). nameservers.addresses sets per-link DNS to
    # public resolvers so external resolution always works. The DHCP-advertised
    # search domain (e.g. adatum.com) is still honored via use-domains default.
    if ($StaticIPv4) {
        if (-not $Gateway) { throw "New-LinuxSeedIso: -Gateway is required when -StaticIPv4 is specified." }
        $networkConfig = @"
version: 2
ethernets:
  primary:
    match:
      name: "e*"
    dhcp4: false
    addresses: [$StaticIPv4/$Prefix]
    routes:
      - to: default
        via: $Gateway
    nameservers:
      addresses: [1.1.1.1, 8.8.8.8]
"@
    }
    else {
        $networkConfig = @"
version: 2
ethernets:
  primary:
    match:
      name: "e*"
    dhcp4: true
    dhcp4-overrides:
      use-dns: false
    nameservers:
      addresses: [1.1.1.1, 8.8.8.8]
"@
    }

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
    lock_passwd: $lockPasswdYaml
    ssh_authorized_keys:
      - $($sshKey.PublicKey)

ssh_pwauth: true
disable_root: false
$chpasswdBlock

# Fallback DNS for the brief window where a VM is up but the domain DC
# (which serves DNS for the lab subnet) hasn't been provisioned yet, so
# cloud-init's package_update can still resolve archive.ubuntu.com etc.
# Once the DC is up and DHCP hands out its IP as the primary DNS,
# systemd-resolved prefers that and only uses these as fallback.
write_files:
  - path: /etc/systemd/resolved.conf.d/memlabs-fallback.conf
    permissions: '0644'
    content: |
      [Resolve]
      FallbackDNS=1.1.1.1 8.8.8.8
  # Helper: once the DC is online and serving DNS for the AD domain,
  # invoke this to make the DC the primary resolver while keeping public
  # resolvers as fallback. Usage (run as root):
  #   memlabs-set-dns 192.168.6.1 [adatum.com]
  # The script writes a netplan drop-in (60-memlabs-dc-dns.yaml) that
  # merges with the cloud-init-generated 50-cloud-init.yaml. Per-link DNS
  # becomes: <DC>, 1.1.1.1, 8.8.8.8 with the AD domain as search suffix.
  - path: /usr/local/sbin/memlabs-set-dns
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euo pipefail
      if [[ `${#} -lt 1 ]]; then
        echo "Usage: `$0 <dc-dns-ip> [search-domain]" >&2
        exit 1
      fi
      DC_DNS="`$1"
      SEARCH="`${2:-}"
      SEARCH_LINE=""
      if [[ -n "`$SEARCH" ]]; then
        SEARCH_LINE="        search: [`$SEARCH]"
      fi
      cat > /etc/netplan/60-memlabs-dc-dns.yaml <<EOF
      network:
        version: 2
        ethernets:
          primary:
            match:
              name: "e*"
            nameservers:
              addresses: [`$DC_DNS, 1.1.1.1, 8.8.8.8]
      `$SEARCH_LINE
      EOF
      chmod 600 /etc/netplan/60-memlabs-dc-dns.yaml
      netplan apply
      systemctl restart systemd-resolved || true
      echo "DNS now: `$(resolvectl dns | grep -v '^`$')"

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
    [System.IO.File]::WriteAllText((Join-Path $stage "network-config"), ($networkConfig -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))

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

function Get-LinuxDomainJoinSeedArgs {
    <#
    .SYNOPSIS
        Build the ExtraPackages + ExtraRunCmd additions needed to realm-join a
        Linux VM to the lab AD domain during cloud-init first boot.

    .DESCRIPTION
        Returns $null when prerequisites aren't met (missing network base, DC,
        or LocalAdmin credential). Otherwise returns a hashtable with:
          ExtraPackages : @(realmd, sssd, ...)
          ExtraRunCmd   : @(wait-for-dns, set-dns, realm-join, mkhomedir, ...)
          DcIp          : resolved DC IPv4 used for DNS reconfig
          AdminUser     : domain admin username used for the join
        Caller merges these into seedArgs before invoking New-LinuxSeedIso.

        Credentials end up in /var/log/cloud-init-output.log on the VM, which
        is an acceptable lab tradeoff (same password is already exposed via
        console login chpasswd in the seed ISO).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$DeployConfig,

        [Parameter(Mandatory = $true)]
        [object]$ThisVm,

        [Parameter(Mandatory = $true)]
        [string]$Domain
    )

    if (-not $DeployConfig -or -not $DeployConfig.vmOptions) { return $null }

    # DC IP: memlabs convention is <network>.1. Prefer the VM's own network
    # if set, otherwise fall back to vmOptions.network.
    $netBase = $ThisVm.network
    if (-not $netBase) { $netBase = $DeployConfig.vmOptions.network }
    if (-not ($netBase -match '^(\d+\.\d+\.\d+)\.\d+$')) {
        Write-Log "Get-LinuxDomainJoinSeedArgs: network '$netBase' isn't /24 a.b.c.0 form; cannot derive DC IP" -Warning
        return $null
    }
    $dcIp = "$($Matches[1]).1"

    # Admin user: vmOptions.adminName is the lab domain admin account.
    $adminUser = $DeployConfig.vmOptions.adminName
    if (-not $adminUser) {
        Write-Log "Get-LinuxDomainJoinSeedArgs: vmOptions.adminName is empty; cannot realm-join" -Warning
        return $null
    }

    # Password from host-side $Common.LocalAdmin. Same password the rest of
    # the lab uses for the domain admin (memlabs convention).
    $adminPwd = $null
    if ($Common -and $Common.LocalAdmin) {
        try { $adminPwd = $Common.LocalAdmin.GetNetworkCredential().Password } catch { $adminPwd = $null }
    }
    if (-not $adminPwd) {
        Write-Log "Get-LinuxDomainJoinSeedArgs: \$Common.LocalAdmin not available; cannot realm-join" -Warning
        return $null
    }

    # Bash single-quote escape: ' -> '\''
    $pwBashSingle = $adminPwd -replace "'", "'\''"
    $domainLower = $Domain.ToLower()

    $extraPackages = @(
        'realmd',
        'sssd',
        'sssd-tools',
        'adcli',
        'krb5-user',
        'packagekit',
        'samba-common-bin',
        'oddjob',
        'oddjob-mkhomedir',
        'libnss-sss',
        'libpam-sss'
    )

    # Quoting hell avoidance: build the join script as bash source, then
    # base64-encode it and emit a single runcmd line:
    #   echo <b64> | base64 -d > /root/join.sh && bash /root/join.sh
    # The script body is opaque to PowerShell here-string parsing, YAML, and
    # bash -c " " word splitting, so no escaping of $/`/"/' is needed inside.
    $joinScript = @"
#!/bin/bash
set -uo pipefail
DOMAIN='$domainLower'
DC_IP='$dcIp'
ADMIN_USER='$adminUser'
ADMIN_PWD='$pwBashSingle'
# Point resolver at the DC so realm discover can find AD SRV records.
/usr/local/sbin/memlabs-set-dns "`$DC_IP" "`$DOMAIN" || true
# Wait up to 20 minutes for the DC's A record to resolve (DC DSC may
# still be coming up when cloud-init runs).
for i in {1..80}; do
  if getent hosts "`$DOMAIN" >/dev/null 2>&1; then break; fi
  echo "memlabs-realm-join: waiting for DNS on `$DOMAIN (attempt `$i/80)"
  sleep 15
done
realm discover "`$DOMAIN" || true
# Retry the join up to 5 times in case the DC accepts auth but hasn't
# fully replicated.
for i in {1..5}; do
  if echo "`$ADMIN_PWD" | realm join -U "`$ADMIN_USER" "`$DOMAIN" --install=/; then
    JOINED=1
    break
  fi
  echo "memlabs-realm-join: join attempt `$i failed, retrying in 30s"
  sleep 30
done
if [ "`${JOINED:-0}" != "1" ]; then
  echo "memlabs-realm-join: ERROR - all join attempts failed"
  exit 1
fi
# Allow login as plain "user" (not "user@domain") and auto-create home dirs.
realm permit --realm "`$DOMAIN" --all || true
sed -i 's/^use_fully_qualified_names = .*/use_fully_qualified_names = False/' /etc/sssd/sssd.conf || true
sed -i 's|^fallback_homedir = .*|fallback_homedir = /home/%u|' /etc/sssd/sssd.conf || true
pam-auth-update --enable mkhomedir || true
systemctl restart sssd || true
# Domain Admins -> sudo NOPASSWD.
echo '%domain\ admins ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/memlabs-domain-admins
chmod 0440 /etc/sudoers.d/memlabs-domain-admins
"@

    # Base64-encode the script (UTF-8 LF line endings) so it survives the
    # YAML/bash quoting layers untouched.
    $scriptLf = $joinScript -replace "`r`n", "`n"
    $scriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($scriptLf))

    $extraRunCmd = @(
        "bash -c 'echo $scriptB64 | base64 -d > /root/memlabs-realm-join.sh && chmod 0700 /root/memlabs-realm-join.sh && /root/memlabs-realm-join.sh; shred -u /root/memlabs-realm-join.sh 2>/dev/null || true'"
    )

    return [pscustomobject]@{
        ExtraPackages = $extraPackages
        ExtraRunCmd   = $extraRunCmd
        DcIp          = $dcIp
        AdminUser     = $adminUser
    }
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

        # Linux guests get static memory. Hyper-V Dynamic Memory on Linux
        # depends on hv_balloon and is historically the flakiest LIS component:
        # it requires a swap partition (cloud images use swapfiles), can fail
        # to balloon up under load, and reports 0 pressure in Hyper-V Manager.
        # The lab Linux VMs (Squid Proxy etc.) are small enough that pinning
        # is fine, and it sidesteps the whole class of issues. Force static
        # regardless of dynamicMinRam.
        $vm | Set-VMMemory -DynamicMemoryEnabled $false -StartupBytes ($Memory / 1) -ErrorAction Stop

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

        # Build and attach the cloud-init seed ISO. Role-specific static IPs
        # (e.g. Proxy pinned to <network>.2) are derived from $DeployConfig
        # and the VM's network, then handed to New-LinuxSeedIso to emit a
        # static netplan config instead of the default DHCP one.
        $seedIsoPath = Join-Path $vm.Path "$VmName-seed.iso"
        $seedArgs = @{
            VmName        = $VmName
            Domain        = $Domain
            OutputIsoPath = $seedIsoPath
        }
        if ($DeployConfig) {
            $thisVm = $DeployConfig.virtualMachines | Where-Object { $_.vmName -eq $VmName } | Select-Object -First 1
            if ($thisVm -and $thisVm.role -eq 'Proxy') {
                $netBase = $thisVm.network
                if (-not $netBase) { $netBase = $DeployConfig.vmOptions.network }
                if ($netBase -match '^(\d+\.\d+\.\d+)\.\d+$') {
                    $base = $Matches[1]
                    $seedArgs.StaticIPv4 = "$base.2"
                    $seedArgs.Gateway = "$base.200"
                    Write-Log "$VmName`: Proxy role detected; pinning to $($seedArgs.StaticIPv4) (gw $($seedArgs.Gateway))"
                }
                else {
                    Write-Log "$VmName`: Proxy role but network '$netBase' isn't /24 a.b.c.0 form; falling back to DHCP" -Warning
                }
            }
            # enableRDP toggle (currently exposed on the Proxy VM in genconfig).
            # When set, install xrdp + a lightweight XFCE desktop and wire the
            # console user into an X session so RDP logins land on a real GUI.
            # The matching RDCMan entry (Common.RdcMan.ps1) supplies vmbuildadmin
            # + the LocalAdmin password for automatic sign-in.
            if ($thisVm -and $thisVm.PSObject.Properties.Name -contains 'enableRDP' -and [bool]$thisVm.enableRDP) {
                Write-Log "$VmName`: enableRDP=true; cloud-init will install xrdp + xfce4 and open TCP/3389"
                $seedArgs.ExtraPackages = @(
                    'xrdp',
                    'xorgxrdp',
                    'xfce4',
                    'xfce4-goodies',
                    'dbus-x11',
                    'xorg',
                    # xfce4 ships only a browser *launcher* (xfce4-web-browser),
                    # not an actual browser, so clicking the globe icon throws
                    # "Failed to execute default Web Browser. Input/output error".
                    # apt-transport-https + the gnupg/wget pair below are
                    # prereqs for adding the Mozilla apt repo in runcmd.
                    'apt-transport-https',
                    'ca-certificates',
                    'gnupg',
                    'wget'
                )
                $seedArgs.ExtraRunCmd = @(
                    # xrdp drops privileges to the 'xrdp' user; that user must
                    # be able to read /etc/ssl/private/ssl-cert-snakeoil.key
                    # to terminate TLS for the RDP handshake.
                    'adduser xrdp ssl-cert || true',
                    # Default session for vmbuildadmin when xrdp's startwm.sh
                    # execs ~/.xsession. xfce4-session pulls in the rest.
                    "install -d -o vmbuildadmin -g vmbuildadmin -m 0755 /home/vmbuildadmin",
                    "bash -c `"echo 'xfce4-session' > /home/vmbuildadmin/.xsession`"",
                    'chown vmbuildadmin:vmbuildadmin /home/vmbuildadmin/.xsession',
                    'chmod 0644 /home/vmbuildadmin/.xsession',
                    # Same default for root in case someone RDPs as root.
                    "bash -c `"echo 'xfce4-session' > /root/.xsession`"",
                    'chmod 0644 /root/.xsession',
                    'ufw allow 3389/tcp || true',
                    'systemctl enable --now xrdp || true',
                    'systemctl enable --now xrdp-sesman || true',
                    # Install Firefox from Mozilla's official apt repo. The
                    # default Ubuntu 'firefox' package is a snap shim that
                    # takes 30s+ to first-launch and pulls in snapd. The
                    # Mozilla deb is a real .deb, launches instantly, and
                    # auto-updates via apt. Pin the repo so apt prefers it
                    # over the transitional Ubuntu package.
                    'install -d -m 0755 /etc/apt/keyrings',
                    'bash -c "wget -qO- https://packages.mozilla.org/apt/repo-signing-key.gpg | tee /etc/apt/keyrings/packages.mozilla.org.asc > /dev/null"',
                    'bash -c "echo ''deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main'' > /etc/apt/sources.list.d/mozilla.list"',
                    'bash -c "printf ''Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n'' > /etc/apt/preferences.d/mozilla"',
                    'apt-get update',
                    'DEBIAN_FRONTEND=noninteractive apt-get install -y firefox',
                    # Make Firefox the system-wide default x-www-browser /
                    # gnome-www-browser so xfce4-web-browser launcher resolves
                    # it (the launcher uses xdg-open -> x-www-browser).
                    'update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/bin/firefox 200 || true',
                    'update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser /usr/bin/firefox 200 || true',
                    'update-alternatives --set x-www-browser /usr/bin/firefox || true',
                    'update-alternatives --set gnome-www-browser /usr/bin/firefox || true',
                    # Tell XDG (used by xfce4-web-browser) that firefox is the
                    # default handler for http/https/text-html. Applied
                    # system-wide via /etc/xdg so it picks up for every user.
                    'install -d -m 0755 /etc/xdg',
                    "bash -c `"cat > /etc/xdg/mimeapps.list <<'EOF'`n[Default Applications]`nx-scheme-handler/http=firefox.desktop`nx-scheme-handler/https=firefox.desktop`ntext/html=firefox.desktop`nEOF`""
                )
            }

            # joinDomain toggle (currently exposed on the LinuxServer VM in
            # genconfig). When true, cloud-init installs realmd/SSSD packages
            # and runs `realm join` against the lab AD domain after waiting
            # for DC DNS to come up. Credentials come from $Common.LocalAdmin
            # (same password used everywhere else in the lab) and
            # $DeployConfig.vmOptions.adminName for the user.
            if ($thisVm -and $thisVm.PSObject.Properties.Name -contains 'joinDomain' -and [bool]$thisVm.joinDomain) {
                $joinExtra = Get-LinuxDomainJoinSeedArgs -DeployConfig $DeployConfig -ThisVm $thisVm -Domain $Domain
                if ($joinExtra) {
                    Write-Log "$VmName`: joinDomain=true; cloud-init will realm-join '$Domain' as user '$($joinExtra.AdminUser)' (DC IP $($joinExtra.DcIp))"
                    $seedArgs.ExtraPackages = @($seedArgs.ExtraPackages) + $joinExtra.ExtraPackages | Where-Object { $_ } | Select-Object -Unique
                    $seedArgs.ExtraRunCmd = @($seedArgs.ExtraRunCmd) + $joinExtra.ExtraRunCmd | Where-Object { $_ }
                }
                else {
                    Write-Log "$VmName`: joinDomain=true but domain-join args could not be resolved (missing DC, network, or admin creds); skipping join" -Warning
                }
            }
        }
        $null = New-LinuxSeedIso @seedArgs
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

function Get-LinuxVmExpectedStaticIP {
    <#
    .SYNOPSIS
        Return the IP a Linux VM is expected to claim, or $null if it uses DHCP.

    .DESCRIPTION
        Mirrors the role-specific static-IP logic in New-LinuxVirtualMachine
        (Proxy -> <network>.2). DHCP-only roles (LinuxServer today, future
        LinuxDesktop) return $null so callers can skip the KVP-independent
        fallback probe -- a DHCP guest's IP isn't predictable from config.

        Keeping this in one place means Wait-LinuxVmReady callers and the
        seed-ISO emitter agree on which VMs have a known IP.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [psobject]$VmObject,

        [Parameter(Mandatory = $false)]
        [psobject]$DeployConfig
    )

    if (-not $VmObject) { return $null }
    if ($VmObject.role -ne 'Proxy') { return $null }

    $netBase = $VmObject.network
    if (-not $netBase -and $DeployConfig) { $netBase = $DeployConfig.vmOptions.network }
    if ($netBase -match '^(\d+\.\d+\.\d+)\.\d+$') {
        return "$($Matches[1]).2"
    }
    return $null
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
        [int]$PollIntervalSeconds = 10,

        # Optional fallback IP to probe alongside KVP. For role-pinned static
        # VMs (e.g. Proxy at <network>.2) we already know the address the
        # guest is supposed to claim; probing it directly lets us succeed
        # even when the guest's KVP daemon (hv_kvp_daemon) failed to start
        # or the Hyper-V Data Exchange service is unhappy. Without this,
        # a fully-up VM with broken KVP looks identical to a dead VM.
        [Parameter(Mandatory = $false)]
        [string]$ExpectedIPAddress
    )

    $sshExe = Get-LinuxSshExePath
    $keyPair = Get-LinuxAdminSshKeyPair
    $knownHostsPath = Join-Path (Split-Path $keyPair.PrivateKeyPath) "known_hosts"

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $startedAt = Get-Date
    Write-Log "$VmName`: Waiting for Linux VM to become SSH-ready (timeout ${TimeoutSeconds}s)"
    Write-Log "$VmName`: SSH probe details: exe=$sshExe key=$($keyPair.PrivateKeyPath) known_hosts=$knownHostsPath" -LogOnly
    if ($ExpectedIPAddress) {
        Write-Log "$VmName`: Will also probe expected static IP $ExpectedIPAddress as a KVP-independent fallback." -LogOnly
    }
    write-progress2 "Wait for Linux VM" -Status "$VmName`: cloud-init running, waiting for IP..." -force

    $lastReportedIp = $null
    $lastHeartbeatSec = 0
    $heartbeatIntervalSec = 60
    $loggedKnownHostsForIp = $null
    $lastSshErrLogSec = -9999
    $sshErrLogIntervalSec = 30
    while ((Get-Date) -lt $deadline) {
        $elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
        $ip = Get-LinuxVmIPAddress -VmName $VmName
        # If KVP hasn't reported yet but the caller told us where the guest
        # is supposed to claim a static IP (Proxy role pins .2, etc.), fall
        # through to that address. We still capture which source paid out
        # so the autopsy log makes the path clear.
        $ipSource = $null
        if ($ip) {
            $ipSource = 'kvp'
        }
        elseif ($ExpectedIPAddress) {
            $ip = $ExpectedIPAddress
            $ipSource = 'expected-static'
        }
        if ($ip) {
            if ($ip -ne $lastReportedIp) {
                Write-Log "$VmName`: got guest IP $ip (source=$ipSource); probing SSH (elapsed ${elapsed}s)"
                write-progress2 "Wait for Linux VM" -Status "$VmName`: got IP $ip ($ipSource), probing SSH (elapsed ${elapsed}s / ${TimeoutSeconds}s)" -force
                $lastReportedIp = $ip
            }

            # One-time per IP: scrub any stale known_hosts entries for this
            # IP. A stale entry from a prior deploy (different host keys)
            # silently breaks ssh.exe even with -o StrictHostKeyChecking=no
            # for the user running ssh interactively. Internal ops bypass
            # known_hosts entirely (UserKnownHostsFile=NUL), but cleaning
            # the cached file helps anyone who later runs ssh by hand.
            if ($ip -ne $loggedKnownHostsForIp) {
                $loggedKnownHostsForIp = $ip
                if (Test-Path $knownHostsPath) {
                    $khEntries = @(Select-String -Path $knownHostsPath -Pattern "^[^ ]*\b$([regex]::Escape($ip))\b" -ErrorAction SilentlyContinue)
                    if ($khEntries.Count -gt 0) {
                        Write-Log "$VmName`: scrubbing $($khEntries.Count) stale known_hosts entry/entries for $ip" -LogOnly
                        try {
                            $allLines = Get-Content -LiteralPath $knownHostsPath -ErrorAction Stop
                            $keep = $allLines | Where-Object { $_ -notmatch "^[^ ]*\b$([regex]::Escape($ip))\b" }
                            Set-Content -LiteralPath $knownHostsPath -Value $keep -Encoding ASCII -NoNewline:$false
                        }
                        catch {
                            Write-Log "$VmName`: failed to scrub known_hosts: $($_.Exception.Message)" -Warning
                        }
                    }
                }
            }

            # NOTE: We deliberately ignore host-key verification for internal
            # probes. Every deploy regenerates the VM's host keys, and a stale
            # entry in known_hosts for this IP from a prior ada-proxy1 will
            # cause ssh.exe to silently abort the handshake (RST [preauth]
            # in sshd's log) even with accept-new (accept-new only writes
            # NEW entries; it rejects mismatches). UserKnownHostsFile=NUL
            # + StrictHostKeyChecking=no bypasses both. Lab vSwitch traffic
            # never leaves the host, so MITM risk is nil.
            $sshArgs = @(
                '-i', $keyPair.PrivateKeyPath,
                '-o', 'StrictHostKeyChecking=no',
                '-o', 'UserKnownHostsFile=NUL',
                '-o', 'BatchMode=yes',
                '-o', 'ConnectTimeout=5',
                '-o', 'LogLevel=ERROR',
                "vmbuildadmin@$ip",
                'true'
            )
            # Capture stderr (was swallowed with 2>$null). Don't spam the
            # log; throttle to once per $sshErrLogIntervalSec.
            $sshErr = & $sshExe @sshArgs 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "$VmName`: SSH ready at $ip" -LogOnly
                write-progress2 "Wait for Linux VM" -Status "$VmName`: SSH ready at $ip" -force -Completed
                return $ip
            }

            if (($elapsed - $lastSshErrLogSec) -ge $sshErrLogIntervalSec) {
                $lastSshErrLogSec = $elapsed
                $errText = ($sshErr | Out-String).Trim()
                if (-not $errText) { $errText = '(no stderr output)' }
                # Also test TCP/22 so we know if sshd is even listening.
                $tcpOk = $false
                try {
                    $tc = [System.Net.Sockets.TcpClient]::new()
                    $iar = $tc.BeginConnect($ip, 22, $null, $null)
                    if ($iar.AsyncWaitHandle.WaitOne(2000, $false)) {
                        $tc.EndConnect($iar) | Out-Null
                        $tcpOk = $tc.Connected
                    }
                    $tc.Close()
                }
                catch { }
                Write-Log "$VmName`: SSH probe failed (elapsed ${elapsed}s, exit=$LASTEXITCODE, tcp/22=$tcpOk): $errText" -LogOnly
            }
        }
        else {
            if (($elapsed - $lastHeartbeatSec) -ge $heartbeatIntervalSec) {
                Write-Log "$VmName`: still waiting for guest IP / cloud-init (elapsed ${elapsed}s / ${TimeoutSeconds}s)"
                $lastHeartbeatSec = $elapsed
            }
            write-progress2 "Wait for Linux VM" -Status "$VmName`: waiting for cloud-init / DHCP (elapsed ${elapsed}s / ${TimeoutSeconds}s)" -force
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }

    Write-Log "$VmName`: Timeout waiting for Linux VM SSH readiness (${TimeoutSeconds}s)" -Failure

    # Final autopsy: capture verbose ssh output so the next run's log tells
    # us *why* SSH never came up (auth failure, no banner, conn refused,
    # host key mismatch, etc.) without needing the VM to still exist.
    if ($lastReportedIp) {
        Write-Log "$VmName`: Final SSH autopsy against $lastReportedIp" -LogOnly
        try {
            $tc = [System.Net.Sockets.TcpClient]::new()
            $iar = $tc.BeginConnect($lastReportedIp, 22, $null, $null)
            $tcpOpen = $false
            if ($iar.AsyncWaitHandle.WaitOne(3000, $false)) {
                $tc.EndConnect($iar) | Out-Null
                $tcpOpen = $tc.Connected
            }
            Write-Log "$VmName`:   TCP/22 open: $tcpOpen" -LogOnly
            if ($tcpOpen) {
                try {
                    $stream = $tc.GetStream()
                    $stream.ReadTimeout = 2000
                    $buf = New-Object byte[] 256
                    Start-Sleep -Milliseconds 800
                    if ($stream.DataAvailable) {
                        $n = $stream.Read($buf, 0, $buf.Length)
                        $banner = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n).Trim()
                        Write-Log "$VmName`:   SSH banner: $banner" -LogOnly
                    }
                    else {
                        Write-Log "$VmName`:   SSH banner: (none; sshd accepted TCP but sent no banner)" -LogOnly
                    }
                }
                catch { Write-Log "$VmName`:   banner read error: $($_.Exception.Message)" -LogOnly }
            }
            $tc.Close()
        }
        catch { Write-Log "$VmName`:   TCP probe error: $($_.Exception.Message)" -LogOnly }

        $verboseSshArgs = @(
            '-i', $keyPair.PrivateKeyPath,
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=NUL',
            '-o', 'BatchMode=yes',
            '-o', 'ConnectTimeout=10',
            '-o', 'LogLevel=DEBUG1',
            "vmbuildadmin@$lastReportedIp",
            'true'
        )
        $verboseOut = & $sshExe @verboseSshArgs 2>&1
        $verboseText = ($verboseOut | Out-String).Trim()
        if ($verboseText) {
            foreach ($line in ($verboseText -split "`r?`n")) {
                Write-Log "$VmName`:   ssh-v> $line" -LogOnly
            }
        }
        Write-Log "$VmName`:   verbose ssh exit code: $LASTEXITCODE" -LogOnly
    }
    else {
        Write-Log "$VmName`: No guest IP was ever reported via KVP; cloud-init/DHCP likely failed inside guest." -LogOnly

        # Expanded autopsy for the no-KVP-IP case. Without this the operator
        # is left guessing whether the VM never booted, booted but couldn't
        # get on the network, or booted+networked but has a broken
        # hv_kvp_daemon. Each of these wants a different fix.
        try {
            $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
            if ($vm) {
                $uptime = if ($vm.Uptime) { [int]$vm.Uptime.TotalSeconds } else { 0 }
                Write-Log "$VmName`:   VM state: $($vm.State); uptime ${uptime}s; heartbeat: $($vm.Heartbeat); status: $($vm.Status)" -LogOnly
            }
            else {
                Write-Log "$VmName`:   Get-VM returned nothing -- VM may have been removed mid-deploy." -LogOnly
            }

            $adapters = Get-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue
            if ($adapters) {
                foreach ($a in $adapters) {
                    $ipsRaw = ($a.IPAddresses -join ', ')
                    if (-not $ipsRaw) { $ipsRaw = '(empty)' }
                    Write-Log "$VmName`:   Adapter '$($a.Name)' switch=$($a.SwitchName) connected=$($a.Connected) mac=$($a.MacAddress) ips=$ipsRaw" -LogOnly
                }
            }
            else {
                Write-Log "$VmName`:   Get-VMNetworkAdapter returned no adapters." -LogOnly
            }

            # Raw KVP exchange items. If this is empty, hv_kvp_daemon never
            # talked to the host (kernel module or userspace daemon missing).
            # If it has FullyQualifiedDomainName etc. but no NetworkAddress*,
            # the daemon is up but networking inside the guest is broken.
            try {
                $vmObj = Get-WmiObject -Namespace 'root\virtualization\v2' -Class 'Msvm_ComputerSystem' `
                    -Filter "ElementName='$VmName'" -ErrorAction Stop
                if ($vmObj) {
                    $kvpSvc = Get-WmiObject -Namespace 'root\virtualization\v2' -Query `
                        "Associators of {$vmObj} Where AssocClass=Msvm_SystemDevice ResultClass=Msvm_KvpExchangeComponent" `
                        -ErrorAction Stop
                    if ($kvpSvc -and $kvpSvc.GuestIntrinsicExchangeItems) {
                        $intrinsicCount = $kvpSvc.GuestIntrinsicExchangeItems.Count
                        Write-Log "$VmName`:   KVP intrinsic items reported: $intrinsicCount (>0 means hv_kvp_daemon is running)" -LogOnly
                        # Pull a few useful keys (OSName, NetworkAddressIPv4, FullyQualifiedDomainName) without dumping all XML.
                        foreach ($itemXml in $kvpSvc.GuestIntrinsicExchangeItems) {
                            try {
                                $x = [xml]$itemXml
                                $name = ($x.INSTANCE.PROPERTY | Where-Object { $_.NAME -eq 'Name' }).VALUE
                                if ($name -in @('OSName', 'NetworkAddressIPv4', 'NetworkAddressIPv6', 'FullyQualifiedDomainName', 'IntegrationServicesVersion')) {
                                    $val = ($x.INSTANCE.PROPERTY | Where-Object { $_.NAME -eq 'Data' }).VALUE
                                    Write-Log "$VmName`:     KVP $name = $val" -LogOnly
                                }
                            }
                            catch { }
                        }
                    }
                    else {
                        Write-Log "$VmName`:   No KVP intrinsic items -- hv_kvp_daemon never ran (missing linux-cloud-tools-virtual?) or VM didn't reach userspace." -LogOnly
                    }
                }
            }
            catch { Write-Log "$VmName`:   KVP enumeration error: $($_.Exception.Message)" -LogOnly }

            # If the caller told us where the guest *should* be, probe it
            # one last time. A successful TCP/22 here while KVP is empty
            # means the guest is fine and only KVP is broken -- worth
            # noting so the next deploy doesn't chase the wrong tail.
            if ($ExpectedIPAddress) {
                try {
                    $tc = [System.Net.Sockets.TcpClient]::new()
                    $iar = $tc.BeginConnect($ExpectedIPAddress, 22, $null, $null)
                    $open = $false
                    if ($iar.AsyncWaitHandle.WaitOne(3000, $false)) {
                        $tc.EndConnect($iar) | Out-Null
                        $open = $tc.Connected
                    }
                    $tc.Close()
                    Write-Log "$VmName`:   Final probe of expected static IP ${ExpectedIPAddress}: TCP/22 open=$open" -LogOnly
                }
                catch { Write-Log "$VmName`:   Final expected-IP probe error: $($_.Exception.Message)" -LogOnly }
            }
        }
        catch { Write-Log "$VmName`:   Autopsy error: $($_.Exception.Message)" -LogOnly }
    }

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

    # See Wait-LinuxVmReady probe comment: ignore host keys for internal SSH.
    # Stale known_hosts from a prior deploy with the same IP silently breaks
    # all subsequent ops; lab vSwitch traffic is host-only so MITM risk is nil.
    $sshArgs = @(
        '-i', $keyPair.PrivateKeyPath,
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=NUL',
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
        # Normalize line endings: PowerShell here-strings on Windows produce
        # CRLF, which bash sees as part of the option/token (yields cryptic
        # errors like "set: -<CR>: invalid option" and "$'\r': command not
        # found"). Strip CR before piping to remote bash -s.
        $payload = $BashCommand -replace "`r`n", "`n" -replace "`r", ""
        $proc.StandardInput.Write($payload)
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

    # NOTE: parameters are passed via -ArgumentList, NOT via $using:. Inside
    # Invoke-VmCommand, $using:VmName resolves to *Invoke-VmCommand's* $VmName
    # parameter ($DCName here, i.e. the DC itself) instead of *this* function's
    # $VmName parameter (the Linux VM). That bug caused us to nuke the DC's own
    # A record and rewrite it to the Linux VM's IP.
    $scriptBlock = {
        param($NodeName, $ZoneName, $NodeIp)
        $node = $NodeName
        $zone = $ZoneName
        $ip   = $NodeIp

        $existing = Get-DnsServerResourceRecord -ZoneName $zone -Node $node -RRType A -ErrorAction SilentlyContinue
        if ($existing) {
            foreach ($r in $existing) {
                Remove-DnsServerResourceRecord -ZoneName $zone -InputObject $r -Force -ErrorAction SilentlyContinue
            }
        }

        # Ensure an AD-integrated /24 reverse lookup zone exists for this IP so
        # -CreatePtr can write the PTR record. memlabs DC build does not create
        # reverse zones by default; without one, Add-DnsServerResourceRecordA
        # -CreatePtr throws *after* writing the A record.
        $octets = $ip.Split('.')
        if ($octets.Count -eq 4) {
            $reverseZone = "$($octets[2]).$($octets[1]).$($octets[0]).in-addr.arpa"
            $networkId   = "$($octets[0]).$($octets[1]).$($octets[2]).0/24"
            $existingZone = Get-DnsServerZone -Name $reverseZone -ErrorAction SilentlyContinue
            if (-not $existingZone) {
                try {
                    Add-DnsServerPrimaryZone -NetworkId $networkId -ReplicationScope Domain -DynamicUpdate Secure -ErrorAction Stop
                }
                catch {
                    # Non-fatal: PTR creation below will just be skipped.
                }
            }
        }

        # Existing PTR (if any) for this IP — remove so PTR points at the new name.
        if ($reverseZone) {
            $ptrName = $octets[3]
            $existingPtr = Get-DnsServerResourceRecord -ZoneName $reverseZone -Node $ptrName -RRType Ptr -ErrorAction SilentlyContinue
            if ($existingPtr) {
                foreach ($p in $existingPtr) {
                    Remove-DnsServerResourceRecord -ZoneName $reverseZone -InputObject $p -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # Write A and PTR as SEPARATE operations. Previous version used
        # Add-DnsServerResourceRecordA -CreatePtr which fails atomically: if
        # the PTR write hits any snag (existing record owned by another
        # principal, zone DDNS scope mismatch, etc.) the A record is never
        # written either -- and the error message often contains "PTR",
        # which the old catch swallowed, leading to a false success log.
        try {
            Add-DnsServerResourceRecordA -ZoneName $zone -Name $node -IPv4Address $ip -ErrorAction Stop
        }
        catch {
            throw "A record write failed for $node.$zone -> $ip : $($_.Exception.Message)"
        }

        # Read back to confirm the A record actually landed in the zone before
        # we declare success. Add-DnsServerResourceRecordA can return without
        # throwing yet leave nothing in the zone in odd ACL scenarios.
        $verify = Get-DnsServerResourceRecord -ZoneName $zone -Node $node -RRType A -ErrorAction SilentlyContinue
        $verifyIp = $verify | ForEach-Object { $_.RecordData.IPv4Address.IPAddressToString } | Where-Object { $_ -eq $ip }
        if (-not $verifyIp) {
            throw "A record write reported success but read-back found no $node.$zone -> $ip in zone"
        }

        # PTR is best-effort: if it fails, forward resolution still works
        # (which is the only thing AD/Kerberos clients need).
        if ($reverseZone) {
            try {
                Add-DnsServerResourceRecordPtr -ZoneName $reverseZone -Name $octets[3] -PtrDomainName "$node.$zone." -ErrorAction Stop
            }
            catch {
                # Swallow: A record (the important part) is already in place.
            }
        }
        return $true
    }

    $result = Invoke-VmCommand -VmName $DCName -VmDomainName $Domain -ScriptBlock $scriptBlock -ArgumentList @($VmName, $Domain, $IPAddress) -DisplayName "Register DNS A: $VmName -> $IPAddress" -CommandReturnsBool
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


function Set-LinuxVmsDcDns {
    <#
    .SYNOPSIS
        Flip all deployed Linux VMs from bootstrap public DNS (1.1.1.1 / 8.8.8.8)
        to use the domain DC as the primary resolver, keeping public DNS as
        fallback.

    .DESCRIPTION
        Linux VMs come up with public DNS pinned in their NoCloud netplan
        (because during Phase 1 the DC isn't online yet and its address would
        time out). Once Phase 2 has provisioned the DC, call this to invoke the
        /usr/local/sbin/memlabs-set-dns helper that the seed ISO installed.
        The helper drops a netplan override making per-link DNS:
            [<DC-IP>, 1.1.1.1, 8.8.8.8]
        with the AD domain set as the search suffix.

        Skips silently if no non-hidden Linux VMs exist in the deployment.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$DeployConfig
    )

    $linuxVms = @($DeployConfig.virtualMachines | Where-Object { (Test-VmIsLinux -Vm $_) -and -not $_.hidden })
    if ($linuxVms.Count -eq 0) {
        return $true
    }

    $domain = $DeployConfig.vmOptions.domainName
    $dcVm = $DeployConfig.virtualMachines | Where-Object { $_.role -eq 'DC' } | Select-Object -First 1
    if (-not $dcVm) {
        $dcVm = Get-List -Type VM -DomainName $domain | Where-Object { $_.role -eq 'DC' } | Select-Object -First 1
    }
    if (-not $dcVm) {
        Write-Log "Set-LinuxVmsDcDns: No DC found for domain '$domain'; skipping" -Warning
        return $true
    }

    # Resolve DC IPv4: prefer Hyper-V-reported, fall back to <network>.1
    # (memlabs convention: DC is always the first usable IP on its subnet).
    $dcIp = $null
    try {
        $dcIp = (Get-VMNetworkAdapter -VMName $dcVm.vmName -ErrorAction Stop).IPAddresses |
            Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } |
            Select-Object -First 1
    }
    catch {}
    if (-not $dcIp) {
        $net = $dcVm.network
        if ($net -and $net -match '^(\d+\.\d+\.\d+)\.\d+$') {
            $dcIp = "$($Matches[1]).1"
        }
    }
    if (-not $dcIp) {
        Write-Log "Set-LinuxVmsDcDns: Could not resolve DC '$($dcVm.vmName)' IPv4; skipping" -Warning
        return $false
    }

    Write-Log "Set-LinuxVmsDcDns: Pointing $($linuxVms.Count) Linux VM(s) at DC $($dcVm.vmName) ($dcIp / $domain)" -Activity
    $allOk = $true
    foreach ($vm in $linuxVms) {
        $cmd = "/usr/local/sbin/memlabs-set-dns $dcIp $domain"
        $res = Invoke-LinuxVmCommand -VmName $vm.vmName -BashCommand $cmd -Sudo `
            -DisplayName "memlabs-set-dns $dcIp $domain" -TimeoutSeconds 60
        if ($res.ScriptBlockFailed -or -not $res.CommandResult) {
            Write-Log "[Linux DNS] $($vm.vmName): failed to flip to DC DNS. $($res.ScriptBlockOutput)" -Warning
            $allOk = $false
        }
        else {
            Write-Log "[Linux DNS] $($vm.vmName): now using DC DNS ($dcIp). $($res.ScriptBlockOutput)" -Success
        }

        # Now that the DC is promoted and has the DNS Server role, register
        # an A record for the Linux VM. In Phase 1 this would have failed
        # because the DC wasn't a DC yet (DSC promotion runs in Phase 2),
        # so the call was deferred to here.
        $vmIp = $null
        try {
            $vmIp = (Get-VMNetworkAdapter -VMName $vm.vmName -ErrorAction Stop).IPAddresses |
                Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } |
                Select-Object -First 1
        }
        catch {}
        if ($vmIp) {
            $null = Register-LinuxVmDns -VmName $vm.vmName -Domain $domain -DCName $dcVm.vmName -IPAddress $vmIp
        }
        else {
            Write-Log "[Linux DNS] $($vm.vmName): could not resolve IPv4; skipping DNS A record registration" -Warning
        }
    }
    return $allOk
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
    $expectedIp = Get-LinuxVmExpectedStaticIP -VmObject $ProxyVM -DeployConfig $deployConfig
    $ip = Wait-LinuxVmReady -VmName $vmName -TimeoutSeconds 900 -ExpectedIPAddress $expectedIp
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

# Fast-path: if squid is already installed, active, and listening on 3128,
# we still rewrite the config (subnets may have changed) and reload, but
# skip apt-get entirely. Saves ~30-60s on re-runs.
FAST_PATH=0
if command -v squid >/dev/null 2>&1 && systemctl is-active --quiet squid && \
   ss -ltn 'sport = :3128' 2>/dev/null | grep -q ':3128'; then
    FAST_PATH=1
fi

if [ "`$FAST_PATH" = "0" ]; then
    # Wait for any background apt/unattended-upgrades to finish (cloud-init
    # may still be running at this point on a freshly-provisioned VM).
    for i in `$(seq 1 60); do
        if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && \
           ! fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
            break
        fi
        sleep 5
    done

    # Recover from a prior hard cancel that left dpkg half-configured.
    # No-op when dpkg is clean.
    dpkg --configure -a || true

    apt-get update -y
    apt-get install -y squid ufw
fi

install -d -m 0755 /etc/squid
NEW_CONF=`$(mktemp)
echo '$confB64' | base64 -d > "`$NEW_CONF"
if [ -f /etc/squid/squid.conf ] && cmp -s "`$NEW_CONF" /etc/squid/squid.conf; then
    rm -f "`$NEW_CONF"
    CONF_CHANGED=0
else
    mv "`$NEW_CONF" /etc/squid/squid.conf
    chmod 0644 /etc/squid/squid.conf
    CONF_CHANGED=1
fi

systemctl enable squid >/dev/null 2>&1 || true
if [ "`$FAST_PATH" = "0" ] || [ "`$CONF_CHANGED" = "1" ]; then
    systemctl restart squid
fi

# Open 3128 in ufw if installed; otherwise just stage the rule.
command -v ufw >/dev/null 2>&1 && ufw allow 3128/tcp || true

# Quick self-test
ss -ltn 'sport = :3128' | grep -q ':3128' || { echo 'squid not listening on 3128'; exit 1; }

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
        Per-VM 'useProxy' is the sole source of truth. domainDefaults
        (UseProxyForCM / UseProxyForClients) are hints used by
        Add-NewVMForRole to seed the per-VM value at creation time and
        are intentionally NOT consulted here. That way, flipping useProxy
        off on every VM is equivalent to the domain having no proxy
        default at all -- the default doesn't override explicit per-VM
        state.

        Returns $false for the Proxy VM itself and for any Linux VM
        (proxy clients are Windows-only). The $DeployConfig parameter is
        kept for source compatibility with callers but is no longer read.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Vm,
        [Parameter(Mandatory = $false)]
        [object]$DeployConfig
    )

    if (-not $Vm) { return $false }
    $hardExclude = @('Proxy', 'DC', 'BDC', 'StandaloneRootCA')
    if ($Vm.role -in $hardExclude) { return $false }
    if (Test-VmIsLinux -Vm $Vm) { return $false }

    if ($Vm.PSObject.Properties.Name -contains 'useProxy') {
        return [bool]$Vm.useProxy
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

            # 4) HKU\.DEFAULT IE settings -- this is what SYSTEM context reads.
            #    .NET WebClient / HttpWebRequest (used by DSC scripts running as
            #    LocalSystem) resolves its default proxy via
            #    WinHttpGetIEProxyConfigForCurrentUser, which for SYSTEM returns
            #    HKU\.DEFAULT, NOT the HKLM keys above (ProxySettingsPerUser=0
            #    only affects WinINet, not .NET's resolver). Without this,
            #    DSC downloads (e.g. InstallODBCDriver fetching msodbcsql.msi
            #    via WebClient) bypass the proxy entirely and hit the ACL
            #    deny rule with "Unable to connect to the remote server".
            $defaultUserKey = 'Registry::HKEY_USERS\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
            if (-not (Test-Path $defaultUserKey)) { New-Item -Path $defaultUserKey -Force | Out-Null }
            New-ItemProperty -Path $defaultUserKey -Name 'ProxyEnable' -PropertyType DWord -Value 1 -Force | Out-Null
            New-ItemProperty -Path $defaultUserKey -Name 'ProxyServer' -PropertyType String -Value $proxyServer -Force | Out-Null
            New-ItemProperty -Path $defaultUserKey -Name 'ProxyOverride' -PropertyType String -Value $bypassList -Force | Out-Null

            # 5) .NET Framework machine.config <defaultProxy>. This is the only
            #    proxy source that SYSTEM-context System.Net.WebClient honors
            #    on Win11 24H2: WinHttpGetIEProxyConfigForCurrentUser returns
            #    empty for SYSTEM regardless of HKLM / HKU\.DEFAULT registry
            #    state, so .NET falls back to direct (which the lab ACL then
            #    blocks as "Unable to connect to the remote server").
            #    Writing <defaultProxy> here fixes ALL DSC downloads in one
            #    shot (InstallODBCDriver, etc.) with no per-script changes.
            $bypassRegexes = @()
            foreach ($e in ($bypassList -split ';')) {
                $e = $e.Trim()
                if (-not $e -or $e -eq '<local>') { continue }  # <local> handled by bypassonlocal attr
                # Convert wildcard pattern to anchored regex: escape dots, *->.*
                $rx = '^' + ([Regex]::Escape($e) -replace '\\\*', '.*') + '$'
                $bypassRegexes += $rx
            }
            $machineConfigPaths = @(
                "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\Config\machine.config",
                "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\Config\machine.config"
            )
            foreach ($mcPath in $machineConfigPaths) {
                if (-not (Test-Path $mcPath)) { continue }
                $xml = [xml](Get-Content -LiteralPath $mcPath -Raw)
                # Use DocumentElement (live XmlElement) instead of $xml.configuration
                # which goes through PS XML adapter and can return a detached view
                # whose AppendChild mutations don't survive Save().
                $configNode = $xml.DocumentElement
                $sysNet = $configNode.SelectSingleNode('system.net')
                if (-not $sysNet) {
                    $sysNet = $xml.CreateElement('system.net')
                    [void]$configNode.AppendChild($sysNet)
                }
                $existing = $sysNet.SelectSingleNode('defaultProxy')
                if ($existing) { [void]$sysNet.RemoveChild($existing) }
                $defProxy = $xml.CreateElement('defaultProxy')
                $defProxy.SetAttribute('enabled', 'true')
                $defProxy.SetAttribute('useDefaultCredentials', 'true')
                $proxyEl = $xml.CreateElement('proxy')
                $proxyEl.SetAttribute('proxyaddress', "http://$proxyServer")
                $proxyEl.SetAttribute('bypassonlocal', 'true')
                $proxyEl.SetAttribute('autoDetect', 'false')
                $proxyEl.SetAttribute('usesystemdefault', 'false')
                [void]$defProxy.AppendChild($proxyEl)
                if ($bypassRegexes.Count -gt 0) {
                    $bypassEl = $xml.CreateElement('bypasslist')
                    foreach ($rx in $bypassRegexes) {
                        $addEl = $xml.CreateElement('add')
                        $addEl.SetAttribute('address', $rx)
                        [void]$bypassEl.AppendChild($addEl)
                    }
                    [void]$defProxy.AppendChild($bypassEl)
                }
                [void]$sysNet.AppendChild($defProxy)
                $xml.Save($mcPath)

                # Verify the write actually persisted (PS XML adapter has
                # bitten us before — see DocumentElement fix). Re-read from
                # disk and confirm <proxy proxyaddress=...> matches.
                $verifyXml = [xml](Get-Content -LiteralPath $mcPath -Raw)
                $verifyProxy = $verifyXml.DocumentElement.SelectSingleNode('system.net/defaultProxy/proxy')
                if (-not $verifyProxy) {
                    throw "machine.config write verification failed: <defaultProxy/proxy> not present after save in $mcPath"
                }
                $expectedAddr = "http://$proxyServer"
                if ($verifyProxy.GetAttribute('proxyaddress') -ne $expectedAddr) {
                    throw "machine.config proxyaddress mismatch in $mcPath (got '$($verifyProxy.GetAttribute('proxyaddress'))', expected '$expectedAddr')"
                }
            }

            # .NET Framework reads machine.config ONCE per AppDomain. If
            # WmiPrvSE.exe (DSC's host) was already running before we wrote
            # <defaultProxy>, the cached AppDomain still has no proxy and
            # any DSC-driven download bypasses the proxy -> hits the deny
            # ACL -> "Unable to connect to the remote server". Killing the
            # WMI provider hosts forces fresh AppDomain load on the next
            # WMI call, which picks up the new machine.config.
            try {
                Get-Process WmiPrvSE -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Get-Process WmiApSrv -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            } catch { }

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
        # Add-to-existing case: Proxy lives in the existing hierarchy, not
        # in the new VM set. Look it up from the running domain inventory.
        $existingProxyName = Get-ExistingForDomain -DomainName $deployConfig.vmOptions.domainName -Role 'Proxy' | Select-Object -First 1
        if ($existingProxyName) {
            $proxyVm = [pscustomobject]@{ vmName = $existingProxyName; role = 'Proxy' }
            Write-Log "[Proxy] Using existing Proxy VM '$existingProxyName' from domain '$($deployConfig.vmOptions.domainName)' for client config"
        }
    }

    if (-not $proxyVm) {
        Write-Log "[Proxy] $($clients.Count) VM(s) have useProxy=true but no Proxy VM is in the config or domain; skipping client config" -Warning
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

function Set-ProxyAdminAccessOnVm {
    <#
    .SYNOPSIS
        Install host's memlabs ed25519 keypair on a Windows VM and create
        Public-Desktop shortcuts for SSHing to the Proxy and tailing the
        Squid access log.

    .DESCRIPTION
        Cloud-init already authorizes the host's ed25519 public key for
        vmbuildadmin on every Linux VM. This drops the matching private
        key (plus .pub) into C:\ProgramData\memlabs\ssh on the target VM
        with admin-only ACLs so an interactive Administrator can ssh
        without typing a password, and stamps two shortcuts on the
        all-users desktop pointing at ssh.exe.

        Idempotent. Safe to call repeatedly.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string]$VmName,
        [Parameter(Mandatory)] [string]$Domain,
        [Parameter(Mandatory)] [string]$ProxyFqdn,
        [Parameter(Mandatory)] [string]$PrivateKeyContent,
        [Parameter(Mandatory)] [string]$PublicKeyContent
    )

    $scriptBlock = {
        param($privKey, $pubKey, $proxyFqdn)
        $ErrorActionPreference = 'Stop'
        try {
            $sshDir = 'C:\ProgramData\memlabs\ssh'
            if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }

            $privPath = Join-Path $sshDir 'memlabs_ed25519'
            $pubPath  = "$privPath.pub"

            # Write LF-only (OpenSSH on Windows is happy with either, but
            # ed25519 PEM blocks prefer LF). Use [IO.File] to avoid BOM.
            [System.IO.File]::WriteAllText($privPath, ($privKey -replace "`r`n", "`n"))
            [System.IO.File]::WriteAllText($pubPath, ($pubKey -replace "`r`n", "`n"))

            # Lock private key down: SYSTEM + Administrators full, no inherit
            $acl = New-Object System.Security.AccessControl.FileSecurity
            $acl.SetAccessRuleProtection($true, $false)
            $sys = New-Object System.Security.AccessControl.FileSystemAccessRule(
                'NT AUTHORITY\SYSTEM', 'FullControl', 'Allow')
            $adm = New-Object System.Security.AccessControl.FileSystemAccessRule(
                'BUILTIN\Administrators', 'FullControl', 'Allow')
            $acl.AddAccessRule($sys)
            $acl.AddAccessRule($adm)
            Set-Acl -Path $privPath -AclObject $acl

            # Locate ssh.exe (built-in OpenSSH client; present on all current
            # server SKUs by default). Fall back to Get-Command.
            $sshExe = 'C:\Windows\System32\OpenSSH\ssh.exe'
            if (-not (Test-Path $sshExe)) {
                $cmd = Get-Command ssh.exe -ErrorAction SilentlyContinue
                if ($cmd) { $sshExe = $cmd.Source }
            }
            if (-not (Test-Path $sshExe)) {
                return @{ Ok = $false; Error = "ssh.exe not found on target VM" }
            }

            $desktop = 'C:\Users\Public\Desktop'
            $shell = New-Object -ComObject WScript.Shell

            # Common ssh args: identity file, batch mode for the tail (no
            # password prompt), accept unknown host key, suppress known_hosts
            # churn. cmd.exe /k keeps the window open after exit so the user
            # can see error messages.
            $sshArgsBase = "-i `"$privPath`" -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL vmbuildadmin@$proxyFqdn"

            # Interactive SSH shell. cmd.exe /k strips outermost quotes when
            # there are 2+ quoted tokens, so wrap with an extra outer pair.
            $lnk1 = Join-Path $desktop "SSH to $proxyFqdn.lnk"
            $sc1 = $shell.CreateShortcut($lnk1)
            $sc1.TargetPath = 'C:\Windows\System32\cmd.exe'
            $sc1.Arguments = "/k `"`"$sshExe`" $sshArgsBase`""
            $sc1.WorkingDirectory = 'C:\'
            $sc1.IconLocation = "$sshExe,0"
            $sc1.Description = "Open an SSH session to $proxyFqdn as vmbuildadmin"
            $sc1.Save()

            # Squid access-log tail
            $lnk2 = Join-Path $desktop 'Squid Access Log.lnk'
            $sc2 = $shell.CreateShortcut($lnk2)
            $sc2.TargetPath = 'C:\Windows\System32\cmd.exe'
            $sc2.Arguments = "/k `"`"$sshExe`" $sshArgsBase sudo tail -F /var/log/squid/access.log`""
            $sc2.WorkingDirectory = 'C:\'
            $sc2.IconLocation = "$sshExe,0"
            $sc2.Description = "Tail /var/log/squid/access.log on $proxyFqdn"
            $sc2.Save()

            return @{ Ok = $true; SshDir = $sshDir; Shortcuts = @($lnk1, $lnk2) }
        }
        catch {
            return @{ Ok = $false; Error = $_.ToString() }
        }
    }

    $result = Invoke-VmCommand -VmName $VmName -VmDomainName $Domain `
        -ScriptBlock $scriptBlock -ArgumentList $PrivateKeyContent, $PublicKeyContent, $ProxyFqdn `
        -DisplayName "Install proxy SSH key + shortcuts"
    if ($result.ScriptBlockFailed) {
        Write-Log "[Proxy] $VmName`: Set-ProxyAdminAccessOnVm ScriptBlockFailed: $($result.ScriptBlockOutput)" -Failure
        return $false
    }
    $payload = $result.ScriptBlockOutput
    if (-not $payload -or -not $payload.Ok) {
        Write-Log "[Proxy] $VmName`: Set-ProxyAdminAccessOnVm failed: $($payload.Error)" -Failure
        return $false
    }
    Write-Log "[Proxy] $VmName`: Installed SSH key + Public Desktop shortcuts (-> $ProxyFqdn)"
    return $true
}

function Set-ProxyAdminAccessForConfig {
    <#
    .SYNOPSIS
        Push the host SSH key + Squid-log shortcuts to every DC and CM
        site-server VM in a deploy config, so operators can SSH to the
        Proxy from those VMs without typing a password.

    .DESCRIPTION
        Scope is limited to roles that an operator routinely RDPs to
        (DC, BDC, CAS, Primary, Secondary, SiteSystem, PassiveSite).
        Skipped entirely if the config contains no Proxy VM.

        Idempotent. Safe to call repeatedly.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [object]$deployConfig
    )

    $proxyVm = $deployConfig.virtualMachines | Where-Object { $_.role -eq 'Proxy' } | Select-Object -First 1
    if (-not $proxyVm) {
        # Add-to-existing case: Proxy may live in the existing hierarchy.
        $existingProxyName = Get-ExistingForDomain -DomainName $deployConfig.vmOptions.domainName -Role 'Proxy' | Select-Object -First 1
        if ($existingProxyName) {
            $proxyVm = [pscustomobject]@{ vmName = $existingProxyName; role = 'Proxy' }
        }
    }
    if (-not $proxyVm) { return $true }

    $adminRoles = @('DC', 'BDC', 'CAS', 'Primary', 'Secondary', 'SiteSystem', 'PassiveSite')
    $targets = @($deployConfig.virtualMachines | Where-Object {
        ($_.role -in $adminRoles) -and -not $_.hidden -and -not (Test-VmIsLinux -Vm $_)
    })
    if (-not $targets) { return $true }

    $key = Get-LinuxAdminSshKeyPair
    $privContent = (Get-Content -Raw -Path $key.PrivateKeyPath)
    $pubContent  = (Get-Content -Raw -Path $key.PublicKeyPath)

    $proxyFqdn = "$($proxyVm.vmName).$($deployConfig.vmOptions.domainName)"

    $ok = $true
    foreach ($vm in $targets) {
        Write-Log "[Proxy] Installing SSH key + shortcuts on $($vm.vmName) -> $proxyFqdn"
        $r = Set-ProxyAdminAccessOnVm -VmName $vm.vmName -Domain $deployConfig.vmOptions.domainName `
                -ProxyFqdn $proxyFqdn -PrivateKeyContent $privContent -PublicKeyContent $pubContent
        if (-not $r) { $ok = $false }
    }
    return $ok
}

function New-HostProxyShortcuts {
    <#
    .SYNOPSIS
        Create "SSH to <proxy>" and "Squid Access Log" shortcuts on the
        deploying user's desktop on the Hyper-V host.

    .DESCRIPTION
        The host already has the memlabs ed25519 keypair cached (under
        vmbuild\cache\ssh) and the matching public key authorized on the
        Proxy VM via cloud-init. This just makes that access discoverable.

        Skipped if no Proxy VM is in the config. Idempotent.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [object]$deployConfig
    )

    $proxyVm = $deployConfig.virtualMachines | Where-Object { $_.role -eq 'Proxy' } | Select-Object -First 1
    if (-not $proxyVm) { return $true }

    try {
        $key = Get-LinuxAdminSshKeyPair
        $sshExe = Get-LinuxSshExePath
        if (-not $sshExe -or -not (Test-Path $sshExe)) {
            Write-Log "[Proxy] Host ssh.exe not found; skipping host desktop shortcuts" -Warning
            return $false
        }

        # Drop the memlabs keypair into the deploying user's ~/.ssh as
        # id_ed25519 so bare `ssh vmbuildadmin@<proxy>` works (without
        # needing -i). Only overwrites the file if it's missing or already
        # contains the memlabs key -- never clobbers a user's own id_ed25519.
        $userSshDir = Join-Path $HOME '.ssh'
        if (-not (Test-Path $userSshDir)) {
            New-Item -ItemType Directory -Path $userSshDir -Force | Out-Null
        }
        $userKey = Join-Path $userSshDir 'id_ed25519'
        $userPub = "$userKey.pub"
        $memlabsPriv = (Get-Content -Raw -Path $key.PrivateKeyPath)
        $memlabsPub  = (Get-Content -Raw -Path $key.PublicKeyPath)

        $shouldWrite = $true
        if (Test-Path $userKey) {
            try {
                $existing = Get-Content -Raw -Path $userKey
                if ($existing.Trim() -eq $memlabsPriv.Trim()) {
                    $shouldWrite = $false  # already the memlabs key
                }
                else {
                    Write-Log "[Proxy] $userKey already exists with a different key; not overwriting. Use -i $($key.PrivateKeyPath) or copy manually." -Warning
                    $shouldWrite = $false
                }
            }
            catch { $shouldWrite = $false }
        }

        if ($shouldWrite) {
            [System.IO.File]::WriteAllText($userKey, ($memlabsPriv -replace "`r`n", "`n"))
            [System.IO.File]::WriteAllText($userPub,  ($memlabsPub  -replace "`r`n", "`n"))

            # OpenSSH refuses to use the key if perms are too loose: only the
            # current user should have access. Strip inheritance, grant just
            # the current user FullControl.
            try {
                $acl = New-Object System.Security.AccessControl.FileSecurity
                $acl.SetAccessRuleProtection($true, $false)
                $me = "$env:USERDOMAIN\$env:USERNAME"
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $me, 'FullControl', 'Allow')
                $acl.AddAccessRule($rule)
                Set-Acl -Path $userKey -AclObject $acl
            }
            catch {
                Write-Log "[Proxy] Failed to tighten ACL on $userKey`: $_" -Warning
            }
            Write-Log "[Proxy] Installed memlabs key at $userKey (bare 'ssh vmbuildadmin@<proxy>' now works)"
        }

        $proxyFqdn = "$($proxyVm.vmName).$($deployConfig.vmOptions.domainName)"
        $desktop = [Environment]::GetFolderPath('Desktop')
        if (-not $desktop -or -not (Test-Path $desktop)) {
            Write-Log "[Proxy] Could not resolve host Desktop folder; skipping shortcuts" -Warning
            return $false
        }

        $shell = New-Object -ComObject WScript.Shell
        $sshArgsBase = "-i `"$($key.PrivateKeyPath)`" -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL vmbuildadmin@$proxyFqdn"

        # cmd.exe /k strips the OUTERMOST pair of quotes when its argument
        # contains 2+ quoted tokens, which would mangle "ssh.exe" "keypath"
        # into ssh.exe" "keypath. Wrap the whole command in an extra outer
        # pair so the inner quotes survive.
        $lnk1 = Join-Path $desktop "SSH to $proxyFqdn.lnk"
        $sc1 = $shell.CreateShortcut($lnk1)
        $sc1.TargetPath = 'C:\Windows\System32\cmd.exe'
        $sc1.Arguments = "/k `"`"$sshExe`" $sshArgsBase`""
        $sc1.WorkingDirectory = 'C:\'
        $sc1.IconLocation = "$sshExe,0"
        $sc1.Description = "Open an SSH session to $proxyFqdn as vmbuildadmin"
        $sc1.Save()

        # Qualify with FQDN on the host so multiple labs/domains don't collide.
        $lnk2 = Join-Path $desktop "Squid Access Log - $proxyFqdn.lnk"
        $sc2 = $shell.CreateShortcut($lnk2)
        $sc2.TargetPath = 'C:\Windows\System32\cmd.exe'
        $sc2.Arguments = "/k `"`"$sshExe`" $sshArgsBase sudo tail -F /var/log/squid/access.log`""
        $sc2.WorkingDirectory = 'C:\'
        $sc2.IconLocation = "$sshExe,0"
        $sc2.Description = "Tail /var/log/squid/access.log on $proxyFqdn"
        $sc2.Save()

        Write-Log "[Proxy] Host desktop shortcuts created for $proxyFqdn"
        return $true
    }
    catch {
        Write-Log "[Proxy] New-HostProxyShortcuts failed: $_" -Warning
        return $false
    }
}

function Remove-HostProxyShortcuts {
    <#
    .SYNOPSIS
        Delete the host-side desktop shortcuts that point at a specific proxy
        FQDN. Called from Remove-VirtualMachine when a Proxy VM is removed.
    .DESCRIPTION
        The shared ~/.ssh/id_ed25519 key is left in place on purpose -- it's
        used by every Linux VM in every memlabs domain, so removing one
        domain must not break access to the others.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string]$ProxyFqdn
    )

    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        if (-not $desktop -or -not (Test-Path $desktop)) { return }

        $candidates = @(
            (Join-Path $desktop "SSH to $ProxyFqdn.lnk"),
            (Join-Path $desktop "Squid Access Log - $ProxyFqdn.lnk")
        )
        foreach ($lnk in $candidates) {
            if (Test-Path $lnk) {
                Remove-Item -Path $lnk -Force -ErrorAction Stop
                Write-Log "[Proxy] Removed host desktop shortcut: $(Split-Path $lnk -Leaf)" -SubActivity
            }
        }
    }
    catch {
        Write-Log "[Proxy] Remove-HostProxyShortcuts ($ProxyFqdn) failed: $_" -Warning
    }
}

function Invoke-LinuxBaseImageBake {
    <#
    .SYNOPSIS
        First-boot a base VHDX on an internet-connected switch, install
        Hyper-V integration daemons + agents via apt, then cloud-init clean
        so the image is pristine for downstream lab deploys.

    .DESCRIPTION
        memlabs lab subnets DNS-forward to the domain DC. Until the DC is
        provisioned, Linux VMs created in phase 1 cannot resolve
        archive.ubuntu.com and apt fails. The Hyper-V KVP daemon is what
        publishes the guest IP back to the host via
        Get-VMNetworkAdapter.IPAddresses; without it, host-side IP discovery
        breaks. Solution: bake the daemons + qemu-guest-agent into the base
        VHDX during image build (which has internet) so deploy time needs
        zero apt.

        Creates a temp Gen2 VM from $VhdxPath, attaches a NoCloud seed ISO
        that installs the packages, runs `cloud-init clean --logs --seed
        --machine-id`, and powers off. Removes the temp VM, leaves the
        modified VHDX in place. Re-runnable; safe if interrupted.

    .PARAMETER VhdxPath
        Path to the VHDX to modify in place.

    .PARAMETER SwitchName
        Hyper-V switch with outbound internet (e.g. 'Default Switch',
        'MemLabsNAT'). Default tries 'Default Switch'.

    .PARAMETER TimeoutMinutes
        Wall-clock cap on the bake VM. Hard powers off on timeout.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VhdxPath,

        [Parameter(Mandatory = $false)]
        [string]$SwitchName = 'Default Switch',

        [Parameter(Mandatory = $false)]
        [int]$TimeoutMinutes = 20,

        # Server: minimal cloud-image + Hyper-V daemons (existing behavior).
        # Desktop: additionally bake `ubuntu-desktop-minimal` + GDM3 + NetworkManager
        # + xrdp into the image so the resulting VHDX boots straight into a real
        # Ubuntu Desktop session for MDM/EDR testing (Intune for Linux, Defender
        # for Endpoint, etc.). Cloud-init still runs at deploy time to consume
        # the per-VM seed ISO; the renderer override below makes it emit netplan
        # configs that NetworkManager owns instead of systemd-networkd.
        [Parameter(Mandatory = $false)]
        [ValidateSet('Server', 'Desktop')]
        [string]$Variant = 'Server'
    )

    if (-not (Test-Path $VhdxPath)) {
        throw "Bake: VHDX '$VhdxPath' not found."
    }
    # Auto-manage only the canonical 'MemLabsNAT' / 'Default Switch' names; for
    # anything exotic, require the caller to have it set up already.
    if ($SwitchName -in @('MemLabsNAT', 'Default Switch')) {
        $createName = 'MemLabsNAT'
        # Get-VMSwitch with -Name throws if no match; use the safe filter form
        # so we can branch on reuse vs. create without try/catch noise.
        $existing = @(Get-VMSwitch -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $createName })
        if ($existing.Count -gt 1) {
            # Duplicate-name switches confuse Hyper-V cmdlets (LINQ Single() throws
            # 'Sequence contains more than one element' from New-VM). Wipe them all
            # and recreate fresh; bake VMs are ephemeral so nothing of value is
            # attached to these switches.
            Write-Log "Bake: found $($existing.Count) switches named '$createName'; removing all and recreating." -Warning
            foreach ($dup in $existing) {
                try {
                    # Remove-VMSwitch has no -Id; pipe the switch object so we
                    # disambiguate by identity rather than name (both dups share
                    # the same name).
                    $dup | Remove-VMSwitch -Force -ErrorAction Stop
                    Write-Log "Bake: removed duplicate switch '$createName' (Id $($dup.Id))." -Success
                }
                catch {
                    throw "Bake: failed to remove duplicate switch '$createName' (Id $($dup.Id)): $($_.Exception.Message)"
                }
            }
            # Also drop the matching NetNat -- it's name-scoped, not switch-scoped,
            # so a stale one survives switch removal and would clash on re-add.
            if (Get-NetNat -Name "${createName}Nat" -ErrorAction SilentlyContinue) {
                Remove-NetNat -Name "${createName}Nat" -Confirm:$false -ErrorAction SilentlyContinue
            }
            $existing = @()
        }
        if ($existing.Count -eq 1) {
            Write-Log "Bake: reusing existing NAT switch '$createName' (host IP / NetNat will be topped up if missing)." -Activity
        }
        else {
            Write-Log "Bake: creating internal NAT switch '$createName' (172.16.200.0/24)..." -Activity
            try {
                New-VMSwitch -SwitchName $createName -SwitchType Internal -ErrorAction Stop | Out-Null
                Write-Log "Bake: created NAT switch '$createName'." -Success
            }
            catch {
                throw "Bake: failed to create NAT switch '$createName': $($_.Exception.Message). Available switches: $((Get-VMSwitch | Select-Object -ExpandProperty Name) -join ', ')"
            }
        }

        # Top up the NAT plumbing whether the switch is new or reused; both
        # New-NetIPAddress and New-NetNat are no-ops if their target already
        # exists at the desired values.
        try {
            $natAdapter = @(Get-NetAdapter | Where-Object { $_.Name -like "*$createName*" })
            if ($natAdapter.Count -eq 0) {
                throw "Bake: switch '$createName' exists but no matching host vNIC ('vEthernet ($createName)') appeared."
            }
            if ($natAdapter.Count -gt 1) {
                Write-Log "Bake: found $($natAdapter.Count) host vNICs matching '*$createName*'; using ifIndex $($natAdapter[0].ifIndex)." -Warning
            }
            $ifIndex = $natAdapter[0].ifIndex
            $existingIp = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -eq '172.16.200.1' }
            if (-not $existingIp) {
                New-NetIPAddress -IPAddress 172.16.200.1 -PrefixLength 24 -InterfaceIndex $ifIndex -ErrorAction Stop | Out-Null
            }
            if (-not (Get-NetNat -Name "${createName}Nat" -ErrorAction SilentlyContinue)) {
                New-NetNat -Name "${createName}Nat" -InternalIPInterfaceAddressPrefix 172.16.200.0/24 -ErrorAction Stop | Out-Null
            }
            $SwitchName = $createName
        }
        catch {
            throw "Bake: failed to configure NAT plumbing on '$createName': $($_.Exception.Message)"
        }
    }
    else {
        # Caller picked a custom switch (e.g. 'External' on host that already has internet); just verify it exists.
        $switch = @(Get-VMSwitch -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $SwitchName })
        if ($switch.Count -eq 0) {
            throw "Bake: Hyper-V switch '$SwitchName' not found. Pick a switch with outbound internet (-BakeSwitchName), or use 'MemLabsNAT' to auto-create one. Available: $((Get-VMSwitch | Select-Object -ExpandProperty Name) -join ', ')"
        }
        if ($switch.Count -gt 1) {
            throw "Bake: found $($switch.Count) Hyper-V switches named '$SwitchName'; remove the duplicates and re-run."
        }
    }

    $vmName = "memlabs-bake-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $stageDir = Join-Path $env:TEMP "memlabs-bake-$vmName"
    $isoPath = Join-Path $stageDir 'seed.iso'
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

    $instanceId = "memlabs-bake-$([guid]::NewGuid().ToString('N'))"
    $metaData = @"
instance-id: $instanceId
local-hostname: memlabs-bake
"@

    # cloud-init bake recipe:
    #   - install KVP/VSS daemons (Hyper-V integration), qemu-guest-agent,
    #     openssh-server (already present but be explicit)
    #   - enable the services (will auto-start at deploy time, no apt needed)
    #   - cloud-init clean: wipe instance state so next boot (with a new
    #     instance-id from the deploy seed) re-runs the full first-boot flow
    #   - truncate machine-id so each deployed VM regenerates a unique one
    #   - remove cloud-init netplan so deploy seed's network config wins
    #   - power off; the script polls VM state and removes the temp VM
    #
    # Desktop variant adds: ubuntu-desktop-minimal + GDM3 + NetworkManager
    # (real Ubuntu Desktop package surface for MDM/EDR posture checks) and
    # xrdp/xorgxrdp so a baked image can be RDP'd into without per-deploy
    # apt traffic. write_files drops cloud.cfg.d/99-network-renderer.cfg so
    # cloud-init at deploy time generates netplan in NetworkManager-renderer
    # form (NM owns the interface; systemd-networkd stays disabled). The
    # final shutdown/cloud-init-clean steps run after this block regardless
    # of variant, so the published VHDX is always a clean first-boot image.
    $desktopPackagesYaml = ''
    $desktopWriteFilesYaml = ''
    $desktopRuncmdYaml = ''
    if ($Variant -eq 'Desktop') {
        $desktopPackagesYaml = @'
  - ubuntu-desktop-minimal
  - gdm3
  - network-manager
  - xrdp
  - xorgxrdp
'@

        $desktopWriteFilesYaml = @'

write_files:
  - path: /etc/cloud/cloud.cfg.d/99-network-renderer.cfg
    content: |
      system_info:
        network:
          renderers: ['NetworkManager']
'@

        $desktopRuncmdYaml = @'
  - systemctl set-default graphical.target
  - systemctl enable gdm3.service || true
  - systemctl disable systemd-networkd.service || true
  - systemctl enable NetworkManager.service || true
  - systemctl enable xrdp.service || true
  - adduser xrdp ssl-cert || true
  - ufw allow 3389/tcp || true
'@
    }

    $userData = @"
#cloud-config
hostname: memlabs-bake
preserve_hostname: false

package_update: true
package_upgrade: false
packages:
  - linux-tools-virtual
  - linux-cloud-tools-virtual
  - qemu-guest-agent
  - openssh-server
$desktopPackagesYaml
$desktopWriteFilesYaml
runcmd:
  - systemctl enable qemu-guest-agent.service || true
  - systemctl enable hv-kvp-daemon.service || true
  - systemctl enable hv-vss-daemon.service || true
$desktopRuncmdYaml
  - cloud-init clean --logs --seed --machine-id || true
  - truncate -s 0 /etc/machine-id
  - rm -f /var/lib/dbus/machine-id
  - rm -f /etc/netplan/50-cloud-init.yaml
  - shutdown -h +1 "memlabs bake complete"
"@

    [System.IO.File]::WriteAllText((Join-Path $stageDir 'meta-data'), ($metaData -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $stageDir 'user-data'), ($userData -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))

    $oscdimg = Get-OscdimgPath
    if ($oscdimg) {
        & $oscdimg -j2 -lcidata -m -n $stageDir $isoPath | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $isoPath)) {
            throw "Bake: oscdimg failed (exit=$LASTEXITCODE) building $isoPath"
        }
    }
    else {
        New-NoCloudSeedIsoWithImapi -SourceDir $stageDir -OutputIsoPath $isoPath -VolumeLabel 'cidata'
        if (-not (Test-Path $isoPath)) { throw "Bake: IMAPI2FS ISO build failed for $isoPath" }
    }

    Write-Log "Bake: creating temp VM '$vmName' from $VhdxPath on switch '$SwitchName' (variant=$Variant)" -Activity
    # Desktop bake pulls ~1.5GB of packages and runs through dpkg postinst
    # hooks for the full GNOME stack; 2GB OOMs partway through. 4GB is plenty
    # for the duration of the bake (the resulting deployed VMs use their own
    # memory setting from the deploy config, this is just for the bake VM).
    $bakeMemoryBytes = if ($Variant -eq 'Desktop') { 4GB } else { 2GB }
    $bakeProcs = if ($Variant -eq 'Desktop') { 4 } else { 2 }
    $vm = New-VM -Name $vmName -Generation 2 -MemoryStartupBytes $bakeMemoryBytes -VHDPath $VhdxPath -SwitchName $SwitchName -ErrorAction Stop
    try {
        Set-VM -VM $vm -ProcessorCount $bakeProcs -CheckpointType Disabled -ErrorAction Stop
        Set-VMFirmware -VM $vm -EnableSecureBoot Off -ErrorAction Stop
        Add-VMDvdDrive -VM $vm -Path $isoPath -ErrorAction Stop
        $hdd = Get-VMHardDiskDrive -VM $vm
        $dvd = Get-VMDvdDrive -VM $vm
        Set-VMFirmware -VM $vm -BootOrder $hdd, $dvd -ErrorAction Stop

        Start-VM -VM $vm -ErrorAction Stop
        Write-Log "Bake: VM started; waiting up to $TimeoutMinutes min for cloud-init + shutdown..."

        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        $clean = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 10
            $state = (Get-VM -Name $vmName -ErrorAction SilentlyContinue).State
            if ($state -eq 'Off') { $clean = $true; break }
        }
        if (-not $clean) {
            Write-Log "Bake: VM did not shutdown within $TimeoutMinutes min; forcing off." -Warning
            Stop-VM -Name $vmName -TurnOff -Force -ErrorAction SilentlyContinue
            throw "Bake VM '$vmName' did not shutdown within $TimeoutMinutes minutes."
        }
        Write-Log "Bake: VM shut down cleanly." -Success
    }
    finally {
        # Remove-VM keeps the VHDX file; we only want to drop the VM config and DVD attachment.
        Remove-VM -Name $vmName -Force -ErrorAction SilentlyContinue
        Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Bake complete on $VhdxPath" -Success
    return $true
}




