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

    # Lock private key down so OpenSSH on Windows will actually use it.
    # Without this, ssh.exe rejects the key ('bad permissions / too open' or
    # 'Permission denied' when run as a non-owner) and silently falls back
    # to password auth. The cache lives under ProgramData which inherits
    # 'Authenticated Users: Read' from the parent -- OpenSSH refuses any key
    # readable beyond {owner, SYSTEM, Administrators}.
    # Apply the same ACL story as the in-VM Set-WindowsClientProxy helper:
    # disable inheritance, owner=BUILTIN\Administrators, only SYSTEM + Admins
    # have FullControl. That works regardless of which admin account invokes
    # ssh (interactive elevated user, scheduled task as SYSTEM, etc.).
    try {
        $acl = Get-Acl -Path $privateKeyPath
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }
        $sysSid = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'
        $admSid = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'
        $acl.SetOwner($admSid)
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sysSid, 'FullControl', 'Allow')))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($admSid, 'FullControl', 'Allow')))
        Set-Acl -Path $privateKeyPath -AclObject $acl
    } catch {
        Write-Log "Failed to lock down ACL on $privateKeyPath`: $_" -Warning
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

function Test-LinuxUserDataYaml {
    <#
    .SYNOPSIS
        Validate a generated cloud-init user-data blob parses as YAML.

    .DESCRIPTION
        Cloud-init's PyYAML loader silently discards a multipart cloud-config
        part whose body fails to parse, taking users / ssh_authorized_keys /
        runcmd with it. The VM then boots without vmbuildadmin and SSH fails
        with 'Permission denied (publickey)' with no host-side breadcrumb.

        Validation strategy (best available wins):
          1. If the `powershell-yaml` module is loadable, use ConvertFrom-Yaml.
             This catches every YAML error the guest would hit.
          2. Otherwise, fall back to a heuristic that targets the known bug
             class for this codebase: an unquoted runcmd item with a `: `
             followed by a YAML indicator char (`*`, `&`, `[`, `{`). PyYAML
             interprets that as a mapping where the value begins with an
             alias / flow indicator, and rejects the whole part.

        Throws (so the deploy fails fast) on any detected issue; the message
        names the line so the next git commit can fix it surgically.

    .OUTPUTS
        None. Returns silently on success.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$UserData,

        [Parameter(Mandatory = $false)]
        [string]$VmName = '(seed)'
    )

    # Try the real YAML parser first.
    $haveYamlModule = $false
    if (Get-Command -Name ConvertFrom-Yaml -ErrorAction SilentlyContinue) {
        $haveYamlModule = $true
    }
    else {
        try {
            Import-Module powershell-yaml -ErrorAction Stop -Verbose:$false | Out-Null
            $haveYamlModule = $true
        }
        catch { $haveYamlModule = $false }
    }

    if ($haveYamlModule) {
        try {
            $null = ConvertFrom-Yaml -Yaml $UserData
            Write-Log "$VmName`: user-data YAML validates (powershell-yaml)" -LogOnly
            return
        }
        catch {
            throw "Generated user-data for $VmName is not valid YAML: $($_.Exception.Message)"
        }
    }

    # Fallback heuristic: scan runcmd items for the `: <indicator>` bug class.
    # We only inspect lines that look like `  - ...` (sequence items at the
    # canonical two-space indent New-LinuxSeedIso emits). This catches the
    # bug we just shipped (`printf 'Package: *\n...`) without needing a
    # YAML dependency on every dev box.
    $lines = $UserData -split "`n"
    $inRunCmd = $false
    $lineNo = 0
    foreach ($rawLine in $lines) {
        $lineNo++
        $line = $rawLine.TrimEnd("`r")

        # Track which top-level section we're in. Indented keys don't reset.
        if ($line -match '^[A-Za-z_][A-Za-z0-9_]*\s*:') {
            $inRunCmd = ($line -match '^runcmd\s*:')
            continue
        }

        if (-not $inRunCmd) { continue }
        if ($line -notmatch '^\s*-\s+') { continue }

        # Strip the leading `  - ` sequence marker, then look for a
        # `: <indicator>` pair anywhere in the value. YAML treats those as
        # mapping-key boundaries with the value starting with an alias /
        # flow node, which PyYAML rejects.
        $itemValue = $line -replace '^\s*-\s+', ''

        # Skip items that are already wrapped in YAML quotes (the emitter
        # may eventually do this; we want the check to stay correct).
        if ($itemValue.StartsWith('"') -or $itemValue.StartsWith("'")) { continue }

        if ($itemValue -match ':\s+([*&\[\{])') {
            $offender = $Matches[1]
            throw "Generated user-data for $VmName has a runcmd line that PyYAML will reject (line $lineNo): '$itemValue' contains ': $offender' which is parsed as a mapping with a YAML alias/flow node value. Quote the runcmd item, base64-encode the script, or move the file content into write_files."
        }

        # Also catch a sequence item whose value itself starts with a YAML
        # indicator (e.g. `- *something` -> alias reference).
        if ($itemValue -match '^[*&]') {
            throw "Generated user-data for $VmName has a runcmd line that starts with a YAML indicator (line $lineNo): '$itemValue'. YAML-quote it or base64-encode."
        }
    }

    Write-Log "$VmName`: user-data passed heuristic YAML check (powershell-yaml not installed; install for full validation)" -LogOnly
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
        # linux-cloud-tools-virtual / linux-tools-virtual are kernel-FLAVOR
        # metapackages (virtual). Ubuntu cloud images run linux-image-generic
        # (or -azure), so the -virtual metas resolve to stubs that never
        # install the hv_kvp_daemon binary matching $(uname -r). Without
        # the matching binary the systemd unit comes up but the daemon
        # exits immediately and KVP stays empty. Install the kernel-exact
        # tools packages here at runtime when $(uname -r) is known.
        #
        # Do NOT restart hv-kvp-daemon.service from runcmd: hv_utils'
        # in-kernel KVP IC registration (~40s into first boot) creates
        # /sys/devices/virtual/misc/vmbus!hv_kvp, and the service has
        # BindsTo= against that device. If we restart while the device
        # node hasn't appeared yet, systemd marks the unit as
        # dependency-failed and won't retry until next boot -- which is
        # exactly the "KVP not reporting" symptom that bit ADA-PROXY1.
        # The reboot below lets the next boot start the daemon cleanly
        # in proper ordering after hv_utils has fully registered.
        # Only fetch kernel-exact tools if the running kernel's tools
        # package isn't already installed. The base image bakes in the
        # matching pair at build time, so this is a no-op (skip the apt
        # round-trip) on the common path. It only kicks in if cloud-init's
        # package_upgrade bumped the kernel on first boot, leaving the
        # baked tools one version stale.
        'dpkg -s "linux-cloud-tools-$(uname -r)" >/dev/null 2>&1 || apt-get install -y "linux-tools-$(uname -r)" "linux-cloud-tools-$(uname -r)" || true',
        'ufw allow OpenSSH || true',
        # systemd-resolved consults FallbackDNS only when no DHCP/static DNS
        # answers. Restart so the dropin in write_files is picked up before
        # cloud-init's package_update tries to resolve archive.ubuntu.com.
        'systemctl restart systemd-resolved || true',
        # Pick up the /etc/systemd/system/hv-kvp-daemon.service override
        # written above. Do NOT restart the unit from runcmd -- if the
        # /dev/vmbus/hv_kvp device node hasn't appeared yet (hv_utils KVP
        # IC registration races first boot), even our override's ExecStartPre
        # poll can't help once systemd has already marked a prior start
        # dependency-failed. The post-cloud-init reboot lets the daemon come
        # up cleanly from the override on next boot.
        'systemctl daemon-reload || true',
        # Enable the KVP daemon so systemd starts it on the post-cloud-init
        # reboot. The bake normally enables it, but if the baked image has a
        # corrupted service file (missing [Install] / WantedBy) the enable
        # silently fails and the service stays disabled in the VHDX. The
        # write_files above writes the correct file; re-enabling here
        # ensures the WantedBy=multi-user.target symlink exists regardless
        # of bake-era bugs.
        'systemctl enable hv-kvp-daemon.service || true',
        # Start the KVP daemon now (don't wait for the post-cloud-init reboot).
        # The override unit's ExecStartPre polls for /dev/vmbus/hv_kvp (up to
        # 60s), and the kernel-exact cloud-tools package was installed above,
        # so the binary exists. Starting now lets KVP report the guest IP to
        # the host before the reboot, unblocking Wait-LinuxVmReady for DHCP
        # VMs (LinuxServer) that have no ExpectedIPAddress fallback.
        'systemctl restart hv-kvp-daemon.service || true',
        # Delete the temporary bake-time console user. The bake runcmd
        # already runs userdel, but if it failed silently (|| true) the
        # account ships in the VHDX and every deployed VM inherits it.
        'userdel -r memlabs 2>/dev/null || true'
    ) + $ExtraRunCmd + @(
        # Diagnostic log copy: enable memlabs-loggrab service so /var/log/cloud-init*
        # gets mirrored to /boot/efi/memlabs/ on every boot. The ESP is FAT32 and
        # readable by Windows via Mount-VHD without ext4 support; that lets the
        # host extract cloud-init.log post-mortem when SSH/console didn't come up.
        # Best-effort: if any of these fail (cloud-init died early, ESP full, ...)
        # we still want runcmd to continue.
        'systemctl daemon-reload || true',
        'systemctl enable memlabs-loggrab.service || true',
        'systemctl start memlabs-loggrab.service || true'
    )
    # Emit each runcmd item as a YAML double-quoted scalar.
    #
    # Why: plain (unquoted) YAML scalars are parsed greedily. A runcmd line
    # like `bash -c "printf 'Package: *\n...' > /etc/apt/preferences.d/mozilla"`
    # contains `: ` followed by `*`, which PyYAML happily parses as a mapping
    # key (`...Package`) with an alias-reference value (`*\n...`). The whole
    # part-001 of user-data then fails to load with
    #     "while scanning an alias ... expected alphabetic or numeric character"
    # and cloud-init silently discards users / ssh_authorized_keys / runcmd
    # so the VM comes up without vmbuildadmin and without our SSH key.
    #
    # Double-quoting sidesteps all of this: inside a YAML "..." scalar only
    # `\` and `"` need escaping, and `: ` / `*` / `&` / `[` / `{` are inert.
    # We escape `\` first (so the second pass doesn't double-escape the
    # backslash we just inserted before `"`). Note that literal `\n` in shell
    # commands (e.g. printf format strings) must become `\\n` in YAML so the
    # parser hands `\n` back to bash verbatim. We also escape embedded LF/CR
    # bytes (a runcmd item built with PowerShell `"..."`n"..."` will contain a
    # real LF) as `\n` / `\r` so the value stays on one YAML line.
    $runcmdYaml = ($runcmd | ForEach-Object {
            $escaped = $_ -replace '\\', '\\' -replace '"', '\"' -replace "`r", '\r' -replace "`n", '\n'
            "  - `"$escaped`""
        }) -join "`n"

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
    #
    # renderer: networkd is mandatory. Desktop Ubuntu 24.04 defaults netplan to
    # the NetworkManager renderer. The NM unmanage config (write_files above)
    # tells NM to ignore eth*, so without an explicit renderer: networkd netplan
    # generates an NM profile that NM immediately ignores — and networkd has no
    # config at all. Result: eth0 stays DOWN, no DHCP, no IP.
    if ($StaticIPv4) {
        if (-not $Gateway) { throw "New-LinuxSeedIso: -Gateway is required when -StaticIPv4 is specified." }
        $networkConfig = @"
version: 2
renderer: networkd
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
renderer: networkd
ethernets:
  primary:
    match:
      name: "e*"
    dhcp4: true
    optional: true
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
  # Diagnostic loggrab: copies cloud-init / system logs to the EFI System
  # Partition (FAT32 at /boot/efi) so the Windows host can read them by
  # mounting the VHDX -- no ext4/WSL/GRUB-console gymnastics required.
  # Runs every boot via memlabs-loggrab.service below; one-shot, fire-and-
  # forget, never fails the boot.
  - path: /usr/local/sbin/memlabs-loggrab
    permissions: '0755'
    content: |
      #!/bin/bash
      set +e
      DEST=/boot/efi/memlabs
      mkdir -p "`$DEST"
      for f in /var/log/cloud-init.log /var/log/cloud-init-output.log /var/log/syslog /var/log/auth.log /var/log/kern.log; do
        [ -r "`$f" ] && cp -f "`$f" "`$DEST/`$(basename `$f)" 2>/dev/null
      done
      {
        echo "host: `$(hostname 2>/dev/null)"
        echo "date: `$(date -Is 2>/dev/null)"
        echo "uptime: `$(cat /proc/uptime 2>/dev/null)"
        echo "kernel: `$(uname -a 2>/dev/null)"
        echo "cloud-init-status:"
        cloud-init status --long 2>/dev/null
      } > "`$DEST/state.txt" 2>/dev/null
      systemctl --no-pager --failed > "`$DEST/failed-units.txt" 2>/dev/null
      sync
      exit 0
  - path: /etc/systemd/system/memlabs-loggrab.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Copy cloud-init and system logs to ESP for host-side debug
      After=cloud-init.target boot-efi.mount
      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/memlabs-loggrab
      RemainAfterExit=no
      [Install]
      WantedBy=multi-user.target
  # ----------------------------------------------------------------------
  # Why this override exists (read before touching):
  #
  # Symptom: on a freshly-built Ubuntu 24.04 Hyper-V VM, the host cannot
  # read the guest's IP address. (Get-VMNetworkAdapter -VMName X).IPAddresses
  # is empty and `systemctl status hv-kvp-daemon` reports:
  #     Active: inactive (dead)
  #     Condition: start condition failed at ...
  #     ConditionPathExists=/dev/vmbus/hv_kvp was not met
  # or:
  #     hv-kvp-daemon.service: Job hv-kvp-daemon.service/start failed
  #         with result 'dependency-failed'.
  #
  # Root cause: the Ubuntu-shipped unit at
  # /usr/lib/systemd/system/hv-kvp-daemon.service contains:
  #     BindsTo=sys-devices-virtual-misc-vmbus\x21hv_kvp.device
  #     ConditionPathExists=/dev/vmbus/hv_kvp
  # Both guards reference a device node that's created by the hv_utils
  # kernel module when it completes KVP Integration Component negotiation
  # with the host. On first boot this can take ~40 seconds. systemd
  # evaluates the guards much earlier than that, marks the unit
  # dependency-failed, and -- by design -- will not retry the unit for
  # the remainder of the boot. KVP stays dark until the next reboot
  # (where the same race can repeat).
  #
  # hv_kvp_daemon talks to the host through /dev/vmbus/hv_kvp directly;
  # it does not need the network. The original guards exist to avoid a
  # busy-loop on systems where hv_utils never loads at all. We achieve
  # the same goal more gracefully with the ExecStartPre poll below.
  #
  # Why a full unit replacement and not a drop-in:
  # We tried /etc/systemd/system/hv-kvp-daemon.service.d/wait-for-device.conf
  # with the documented empty-list reset:
  #     [Unit]
  #     BindsTo=
  #     ConditionPathExists=
  # On Ubuntu 24.04's systemd this loads (systemctl cat shows it merged)
  # but does NOT clear the parent values (systemctl show still reports
  # the original BindsTo= and ConditionPathExists=). This is a known
  # systemd merge-behavior quirk for device-bound BindsTo on that
  # version. A full unit at /etc/systemd/system/ wins outright over
  # /usr/lib/systemd/system/ -- no merge, no surprises.
  #
  # Surgical diff vs Ubuntu's original unit:
  #   - REMOVED BindsTo=...hv_kvp.device       (the racy guard)
  #   - REMOVED ConditionPathExists=/dev/vmbus/hv_kvp (the racy guard)
  #   - ADDED   systemd-modules-load.service in After= (kmod-load gating)
  #   - ADDED   TimeoutStartSec=75    (bound the poll explicitly)
  #   - ADDED   ExecStartPre poll (graceful wait, up to 60s)
  #   - ADDED   Restart=on-failure / RestartSec=5 (upstream had none)
  # Everything else (DefaultDependencies=no, Conflicts=shutdown.target,
  # Before=walinuxagent.service, RequiresMountsFor=/var/lib/hyperv,
  # WantedBy=multi-user.target, ConditionVirtualization=microsoft,
  # ConditionKernelCommandLine=!snapd_recovery_mode) is copied verbatim
  # from upstream so future Ubuntu changes are easy to spot in a diff.
  #
  # If Ubuntu eventually ships an upstream fix (e.g. drops BindsTo= or
  # the systemd merge bug is fixed and a drop-in becomes viable), this
  # whole block can be removed -- nothing else in memlabs depends on it.
  # ----------------------------------------------------------------------
  - path: /etc/systemd/system/hv-kvp-daemon.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Hyper-V KVP Protocol Daemon (memlabs override)
      ConditionVirtualization=microsoft
      ConditionKernelCommandLine=!snapd_recovery_mode
      DefaultDependencies=no
      After=systemd-remount-fs.service systemd-modules-load.service
      Before=shutdown.target cloud-init-local.service walinuxagent.service
      Conflicts=shutdown.target
      RequiresMountsFor=/var/lib/hyperv
      [Service]
      # Poll bound is 60s; set TimeoutStartSec=75s so the script owns the
      # timeout and systemd doesn't race it (default TimeoutStartSec=90s
      # is close enough to the poll bound to be ambiguous in logs).
      TimeoutStartSec=75
      ExecStartPre=/bin/bash -c 'for i in `$(seq 1 60); do [ -e /dev/vmbus/hv_kvp ] && exit 0; sleep 1; done; exit 1'
      ExecStart=/usr/sbin/hv_kvp_daemon -n
      Restart=on-failure
      RestartSec=5
      [Install]
      WantedBy=multi-user.target
  # NetworkManager unmanage config: on Desktop images NM is installed
  # alongside systemd-networkd. Without this file NM auto-manages eth*
  # and races networkd for the DHCP lease. On Server images NM isn't
  # installed so this file is a harmless no-op.
  # Also written during bake (bakeWriteFilesYaml); having it here ensures
  # deployed VMs always have it regardless of bake-era bugs.
  - path: /etc/NetworkManager/conf.d/10-memlabs-unmanage-eth.conf
    permissions: '0644'
    content: |
      [keyfile]
      unmanaged-devices=interface-name:eth*

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

    # Pre-flight: validate user-data parses as YAML before we write it to the
    # ISO. Cloud-init's PyYAML loader silently discards a part whose body
    # fails to parse, dropping users / ssh_authorized_keys / runcmd along
    # with it -- the VM then boots without vmbuildadmin and SSH fails with
    # 'Permission denied (publickey)' with NO host-side breadcrumb. We've
    # been bitten by this twice (most recently: a printf runcmd containing
    # `Package: *\n` parsed as a YAML alias reference). Catching it here
    # turns a multi-hour WSL-mount-the-ext4-rootfs debug session into a
    # one-line build failure.
    $userDataLf = $userData -replace "`r`n", "`n"
    Test-LinuxUserDataYaml -UserData $userDataLf -VmName $VmName

    # cloud-init expects LF line endings; .NET WriteAllText defaults to whatever
    # was in the string. Force LF by replacing CRLF before write.
    [System.IO.File]::WriteAllText((Join-Path $stage "meta-data"), ($metaData -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $stage "user-data"), $userDataLf, [System.Text.UTF8Encoding]::new($false))
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

        # Wipe any stale VM directory from a previous deploy. SilentlyContinue
        # on the first pass swallows transient file locks (Hyper-V Worker still
        # holding handles after a failed/partial Remove-Lab), so we then
        # verify and retry loudly. If we don't catch this, the next Get-File
        # below may copy on top of yesterday's VHDX (BITS is permissive) and
        # the VM boots stale state with the wrong (or no) vmbuildadmin user,
        # causing 'Permission denied (publickey)' AND console-login failure
        # despite the seed ISO being correct.
        $vmSubPath = Join-Path $VmPath $VmName
        if (Test-Path $vmSubPath) {
            Remove-Item -Path $vmSubPath -Force -Recurse -ErrorAction SilentlyContinue
            if (Test-Path $vmSubPath) {
                Write-Log "$VmName`: Initial cleanup of $vmSubPath failed; retrying after 5s" -Warning
                Start-Sleep -Seconds 5
                try {
                    Remove-Item -Path $vmSubPath -Force -Recurse -ErrorAction Stop
                }
                catch {
                    Write-Log "$VmName`: Could not remove stale VM dir $vmSubPath`: $($_.Exception.Message). Refusing to deploy on top of a stale OS disk." -Failure -OutputStream
                    return $false
                }
            }
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
        # Defensive: New-VM (above) just created $vm.Path fresh, so this file
        # should not exist. If it does, something else left it behind --
        # refuse rather than risk Get-File/BITS copying on top of a stale
        # disk (which is what produced the 'Permission denied (publickey)' +
        # console-login failure symptom described in the commit message).
        if (Test-Path $osDiskPath) {
            try {
                Remove-Item -Path $osDiskPath -Force -ErrorAction Stop
            }
            catch {
                Write-Log "$VmName`: Existing OS disk $osDiskPath could not be removed: $($_.Exception.Message)" -Failure -OutputStream
                return $false
            }
        }
        $worked = Get-File -Source $SourceDiskPath -Destination $osDiskPath `
            -DisplayName "Copying Linux base image to $osDiskPath" -Action "Copying"
        if (-not $worked) {
            Write-Log "$VmName`: Failed to copy $SourceDiskPath -> $osDiskPath." -Failure
            return $false
        }
        # Sanity-check the copy actually produced a fresh disk. If the source
        # is 3GB and the destination is 0 bytes or radically smaller, BITS
        # silently no-op'd over a stale file or hit a file-lock; better to
        # bail now than boot a broken VM and waste 5+ minutes on SSH probes.
        $srcLen = (Get-Item -LiteralPath $SourceDiskPath).Length
        $dstLen = (Get-Item -LiteralPath $osDiskPath -ErrorAction SilentlyContinue).Length
        if (-not $dstLen -or $dstLen -lt ($srcLen * 0.5)) {
            Write-Log "$VmName`: OS disk copy looks suspect (src=$srcLen dst=$dstLen). Refusing to continue." -Failure -OutputStream
            return $false
        }

        Enable-VMIntegrationService -VMName $VmName -Name "Guest Service Interface" -ErrorAction SilentlyContinue | Out-Null

        # Wire COM1 to a named pipe so the host can capture the kernel +
        # cloud-init console stream live. Ubuntu cloud images already have
        # `console=ttyS0` on the kernel cmdline, so everything from GRUB
        # onward streams here. The pipe is server-side (we own the path);
        # attach with `vmbuild\Get-LinuxSerialTap.ps1 -VmName <name>` from
        # another pwsh tab BEFORE Start-VM to capture the full boot. If no
        # one is listening, Hyper-V drops bytes silently -- no guest hang.
        $serialPipe = "\\.\pipe\memlabs-$VmName-com1"
        try {
            Set-VMComPort -VMName $VmName -Number 1 -Path $serialPipe -ErrorAction Stop
            Write-Log "$VmName`: COM1 -> $serialPipe (attach with Get-LinuxSerialTap.ps1)"
        }
        catch {
            Write-Log "$VmName`: Set-VMComPort failed: $_" -Warning
        }

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
            # enableRDP toggle: previously installed xrdp+xfce4+Firefox via
            # cloud-init runcmd. That path was fragile (PyYAML aliased the
            # Mozilla "Package: *" pin line and dropped the whole user-data
            # part) and bloated cloud-init by ~3-5 minutes of apt installs.
            # Now deferred to Phase 3 ($global:Linux_Configure ->
            # Invoke-LinuxRoleConfiguration) which ships one base64-encoded
            # bash script over SSH and runs in parallel with Windows DSC jobs.
            if ($thisVm -and $thisVm.PSObject.Properties.Name -contains 'enableRDP' -and [bool]$thisVm.enableRDP) {
                Write-Log "$VmName`: enableRDP=true noted; xrdp/xfce4/Firefox deferred to Phase 3 Linux_Configure"
            }

            # joinDomain toggle (currently exposed on the LinuxServer VM in
            # genconfig). The realm-join CANNOT happen in cloud-init during
            # Phase 1 (VM_Create) because the DC doesn't get promoted until
            # Phase 2 DSC. Baking the join into runcmd just makes cloud-init
            # block on its 20-min getent-loop waiting for DC DNS that won't
            # exist yet. Defer to a post-Phase-2 step that SSHs into the
            # Linux VM and runs the realm-join script (Phase 1d/1e work).
            # Keep Get-LinuxDomainJoinSeedArgs around -- it's the right
            # script body, just needs a different trigger.
            if ($thisVm -and $thisVm.PSObject.Properties.Name -contains 'joinDomain' -and [bool]$thisVm.joinDomain) {
                Write-Log "$VmName`: joinDomain=true noted; deferred to post-DC phase (DC isn't online during VM_Create)"
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

function Get-LinuxVmWaitTimeout {
    <#
    .SYNOPSIS
        Return the SSH-ready timeout (in seconds) for a Linux VM.

    .DESCRIPTION
        Returns a flat 900s (15 min). SSH-ready means sshd is listening
        and the IP is published via KVP (or matches the expected static
        IP for the role). sshd starts in cloud-init's `config` stage,
        which is long before `final`/runcmd runs the slow add-on installs
        (xfce4 + xrdp + Firefox for enableRDP, realmd stack for
        joinDomain). So those add-ons should NOT push past the base
        budget for the SSH-ready check itself.

        Historical context: a 900s timeout was observed on ADA-PROXY1.
        Root cause was the Hyper-V KVP daemon failing to publish a guest
        IP, not a slow apt install. Wait-LinuxVmReady now falls back to
        the role's expected static IP (see Get-LinuxVmExpectedStaticIP)
        when KVP is silent, so that failure mode no longer needs a
        budget bump.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [psobject]$VmObject
    )

    return 900
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

function Save-LinuxAutopsyLogs {
    <#
    .SYNOPSIS
        On SSH-ready timeout, stop the VM, mount its VHDX read-only, and
        copy cloud-init.log + state.txt off the FAT32 ESP for host-side
        post-mortem.

    .DESCRIPTION
        The `memlabs-loggrab` service inside the guest mirrors cloud-init
        logs to /boot/efi/memlabs on every boot. That partition is FAT32
        and readable from Windows via Mount-VHD -- no WSL, no ext4 tooling
        required. This function automates that mount/copy/dismount dance
        so the operator never has to do it manually.

        Sequence:
          1. Stop-VM -TurnOff -Force  (Mount-VHD refuses a running VM's disk)
          2. Mount-VHD -ReadOnly -NoDriveLetter
          3. For each partition that looks like FAT and contains \memlabs\,
             copy cloud-init.log, cloud-init-output.log, state.txt,
             failed-units.txt to <LogsDir>\linux-autopsy\<VmName>\
          4. Tail cloud-init.log (last 80 lines) into the deploy log so the
             cause shows up in VMBuild.log alongside the timeout message.
          5. Dismount-VHD (always, in finally).

        Best-effort: any failure is logged but does not throw. The VM is
        left stopped so the operator can mount the VHDX themselves if
        more digging is needed.

    .OUTPUTS
        $true on success, $false on any failure (logged but not thrown).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    try {
        $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
        if (-not $vm) {
            Write-Log "$VmName`: autopsy: VM not found, skipping ESP log dump" -LogOnly
            return $false
        }
        $vhdx = ($vm.HardDrives | Select-Object -First 1).Path
        if (-not $vhdx -or -not (Test-Path -LiteralPath $vhdx)) {
            Write-Log "$VmName`: autopsy: VHDX path not resolvable ($vhdx), skipping ESP log dump" -LogOnly
            return $false
        }

        # Mount-VHD needs the disk file unlocked. Stop the VM forcefully --
        # at this point we've already declared SSH timeout, so the VM is
        # going to be rebuilt or manually fixed; no harm in turning it off.
        if ($vm.State -ne 'Off') {
            Write-Log "$VmName`: autopsy: stopping VM (TurnOff) so VHDX can be mounted for log extraction" -LogOnly
            try { Stop-VM -Name $VmName -TurnOff -Force -ErrorAction Stop }
            catch {
                Write-Log "$VmName`: autopsy: Stop-VM failed: $($_.Exception.Message)" -LogOnly
                return $false
            }
            # Hyper-V occasionally takes a beat to release the disk handle.
            Start-Sleep -Seconds 2
        }

        $logsDir = if ($Common -and $Common.LogPath) { Split-Path -Parent $Common.LogPath } else { $env:TEMP }
        $destDir = Join-Path $logsDir "linux-autopsy\$VmName"
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

        $mounted = $null
        try {
            $mounted = Mount-VHD -Path $vhdx -ReadOnly -NoDriveLetter -Passthru -ErrorAction Stop
        }
        catch {
            Write-Log "$VmName`: autopsy: Mount-VHD '$vhdx' failed: $($_.Exception.Message)" -LogOnly
            return $false
        }

        $copiedAny = $false
        try {
            $disk = $mounted | Get-Disk -ErrorAction Stop
            $parts = $disk | Get-Partition -ErrorAction SilentlyContinue
            foreach ($p in $parts) {
                # The ESP on an Ubuntu image is a small FAT32 partition.
                # Drive-letterless mounts surface via Get-Volume off the
                # partition, with FileSystem='FAT32' (or sometimes 'FAT').
                $vol = $null
                try { $vol = $p | Get-Volume -ErrorAction Stop } catch { $vol = $null }
                if (-not $vol) { continue }
                if ($vol.FileSystem -notmatch '^(FAT|FAT32|exFAT)$') { continue }

                # Assign a temporary mount-point folder so we can read it.
                $mountPoint = Join-Path $env:TEMP ("memlabs-esp-{0}-{1}" -f $VmName, [guid]::NewGuid().ToString('N').Substring(0, 8))
                New-Item -ItemType Directory -Path $mountPoint -Force | Out-Null
                try {
                    Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $p.PartitionNumber -AccessPath $mountPoint -ErrorAction Stop
                }
                catch {
                    Write-Log "$VmName`: autopsy: cannot assign access path to partition $($p.PartitionNumber): $($_.Exception.Message)" -LogOnly
                    Remove-Item $mountPoint -Force -ErrorAction SilentlyContinue
                    continue
                }

                try {
                    $memlabsDir = Join-Path $mountPoint 'memlabs'
                    if (Test-Path -LiteralPath $memlabsDir) {
                        Write-Log "$VmName`: autopsy: found ESP\memlabs on partition $($p.PartitionNumber); copying logs to $destDir" -LogOnly
                        Get-ChildItem -LiteralPath $memlabsDir -File -ErrorAction SilentlyContinue | ForEach-Object {
                            try {
                                Copy-Item -LiteralPath $_.FullName -Destination $destDir -Force -ErrorAction Stop
                                $copiedAny = $true
                            }
                            catch { Write-Log "$VmName`: autopsy: copy $($_.Name) failed: $($_.Exception.Message)" -LogOnly }
                        }

                        # Tail cloud-init.log into VMBuild.log so the cause
                        # shows up next to the SSH timeout message and the
                        # operator doesn't have to know about $destDir at all.
                        $ciLog = Join-Path $destDir 'cloud-init.log'
                        if (Test-Path -LiteralPath $ciLog) {
                            $tail = Get-Content -LiteralPath $ciLog -Tail 80 -ErrorAction SilentlyContinue
                            if ($tail) {
                                Write-Log "$VmName`: autopsy: ---- cloud-init.log (last 80 lines) ----" -LogOnly
                                foreach ($t in $tail) { Write-Log "$VmName`: ci> $t" -LogOnly }
                                Write-Log "$VmName`: autopsy: ---- end cloud-init.log tail ----" -LogOnly
                            }
                        }

                        # state.txt has a one-glance summary cloud-init status
                        # + uptime + failed units; surface it on-screen too.
                        $stateTxt = Join-Path $destDir 'state.txt'
                        if (Test-Path -LiteralPath $stateTxt) {
                            $stateLines = Get-Content -LiteralPath $stateTxt -ErrorAction SilentlyContinue
                            foreach ($s in $stateLines) { Write-Log "$VmName`: state> $s" -LogOnly }
                        }
                    }
                }
                finally {
                    try { Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $p.PartitionNumber -AccessPath $mountPoint -ErrorAction Stop }
                    catch { Write-Log "$VmName`: autopsy: Remove-PartitionAccessPath failed: $($_.Exception.Message)" -LogOnly }
                    Remove-Item $mountPoint -Force -ErrorAction SilentlyContinue
                }
            }
        }
        finally {
            try { Dismount-VHD -Path $vhdx -ErrorAction Stop }
            catch { Write-Log "$VmName`: autopsy: Dismount-VHD failed: $($_.Exception.Message)" -LogOnly }
        }

        if ($copiedAny) {
            Write-Log "$VmName`: autopsy: ESP logs saved to $destDir" -OutputStream
            return $true
        }
        else {
            Write-Log "$VmName`: autopsy: no \memlabs\ directory found on any FAT partition (memlabs-loggrab may not have run yet)" -LogOnly
            return $false
        }
    }
    catch {
        Write-Log "$VmName`: autopsy: unexpected error: $($_.Exception.Message)" -LogOnly
        return $false
    }
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
    $lastHeartbeatSec = -30  # Fire first heartbeat (with KVP diagnostics) after ~30s instead of 60s
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
                $lastReportedIp = $ip
            }
            # Cheap TCP/22 probe each iteration so the progress text reflects
            # whether sshd is even listening yet. Avoids the appearance of
            # "stuck at elapsed 0s" while ssh.exe is internally retrying.
            $tcpProbeOk = $false
            try {
                $tc = [System.Net.Sockets.TcpClient]::new()
                $iar = $tc.BeginConnect($ip, 22, $null, $null)
                if ($iar.AsyncWaitHandle.WaitOne(1000, $false)) {
                    $tc.EndConnect($iar) | Out-Null
                    $tcpProbeOk = $tc.Connected
                }
                $tc.Close()
            }
            catch { }
            $tcpLabel = if ($tcpProbeOk) { 'tcp/22 open' } else { 'tcp/22 closed' }
            write-progress2 "Wait for Linux VM" -Status "$VmName`: IP $ip ($ipSource), $tcpLabel, probing SSH (elapsed ${elapsed}s / ${TimeoutSeconds}s)" -force

            # One-time per IP: scrub any stale known_hosts entries for this
            # IP. A stale entry from a prior deploy (different host keys)
            # silently breaks ssh.exe even with -o StrictHostKeyChecking=no
            # for the user running ssh interactively. Internal ops bypass
            # known_hosts entirely (UserKnownHostsFile=NUL), but cleaning
            # the cached files helps anyone who later runs ssh by hand.
            # We scrub BOTH the memlabs-private known_hosts (next to the
            # shared key) AND the host user's default ~/.ssh/known_hosts
            # (which is what `ssh vmbuildadmin@<ip>` actually consults).
            if ($ip -ne $loggedKnownHostsForIp) {
                $loggedKnownHostsForIp = $ip
                $userKnownHosts = Join-Path $env:USERPROFILE '.ssh\known_hosts'
                $scrubTargets = @($knownHostsPath, $userKnownHosts) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
                foreach ($kh in $scrubTargets) {
                    try {
                        $pattern = "^[^ ]*\b$([regex]::Escape($ip))\b"
                        $khEntries = @(Select-String -Path $kh -Pattern $pattern -ErrorAction SilentlyContinue)
                        if ($khEntries.Count -gt 0) {
                            Write-Log "$VmName`: scrubbing $($khEntries.Count) stale known_hosts entry/entries for $ip in $kh" -LogOnly
                            $allLines = Get-Content -LiteralPath $kh -ErrorAction Stop
                            $keep = $allLines | Where-Object { $_ -notmatch $pattern }
                            Set-Content -LiteralPath $kh -Value $keep -Encoding ASCII -NoNewline:$false
                        }
                    }
                    catch {
                        Write-Log "$VmName`: failed to scrub $kh`: $($_.Exception.Message)" -Warning
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
                Write-Log "$VmName`: SSH probe failed (elapsed ${elapsed}s, exit=$LASTEXITCODE, tcp/22=$tcpProbeOk): $errText" -LogOnly
            }
        }
        else {
            if (($elapsed - $lastHeartbeatSec) -ge $heartbeatIntervalSec) {
                Write-Log "$VmName`: still waiting for guest IP / cloud-init (elapsed ${elapsed}s / ${TimeoutSeconds}s)"
                $lastHeartbeatSec = $elapsed

                # Inline KVP diagnostics so we can see what Hyper-V knows
                # about the guest without waiting for the post-timeout autopsy.
                try {
                    $vmInfo = Get-VM -Name $VmName -ErrorAction SilentlyContinue
                    if ($vmInfo) {
                        Write-Log "$VmName`:   heartbeat=$($vmInfo.Heartbeat) state=$($vmInfo.State) uptime=$([int]$vmInfo.Uptime.TotalSeconds)s" -LogOnly
                    }
                    $adapters = Get-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue
                    if ($adapters) {
                        foreach ($a in $adapters) {
                            $ipsRaw = ($a.IPAddresses -join ', ')
                            if (-not $ipsRaw) { $ipsRaw = '(empty)' }
                            Write-Log "$VmName`:   adapter '$($a.Name)': switch=$($a.SwitchName) connected=$($a.Connected) mac=$($a.MacAddress) ips=[$ipsRaw]" -LogOnly
                        }
                    }
                    $vmObj = Get-WmiObject -Namespace 'root\virtualization\v2' -Class 'Msvm_ComputerSystem' `
                        -Filter "ElementName='$VmName'" -ErrorAction SilentlyContinue
                    if ($vmObj) {
                        $kvpSvc = Get-WmiObject -Namespace 'root\virtualization\v2' -Query `
                            "Associators of {$vmObj} Where AssocClass=Msvm_SystemDevice ResultClass=Msvm_KvpExchangeComponent" `
                            -ErrorAction SilentlyContinue
                        if ($kvpSvc -and $kvpSvc.GuestIntrinsicExchangeItems) {
                            $intrinsicCount = $kvpSvc.GuestIntrinsicExchangeItems.Count
                            Write-Log "$VmName`:   KVP intrinsic items: $intrinsicCount" -LogOnly
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
                            Write-Log "$VmName`:   KVP: no intrinsic items (hv_kvp_daemon not running or hasn't reported yet)" -LogOnly
                        }
                    }
                }
                catch { Write-Log "$VmName`:   KVP heartbeat diagnostics error: $($_.Exception.Message)" -LogOnly }
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

    # Last-resort autopsy: the guest's memlabs-loggrab service copies
    # cloud-init.log to the FAT32 ESP on every boot. Mount the VHDX
    # read-only and pull those logs to the host so the next iteration of
    # this debug cycle doesn't require WSL + ext4 + ssh-agent gymnastics.
    # Stops the VM (it's already declared dead) so Mount-VHD can attach.
    try { Save-LinuxAutopsyLogs -VmName $VmName | Out-Null } catch { Write-Log "$VmName`: Save-LinuxAutopsyLogs threw: $($_.Exception.Message)" -LogOnly }

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
    $waitTimeout = Get-LinuxVmWaitTimeout -VmObject $ProxyVM
    $ip = Wait-LinuxVmReady -VmName $vmName -TimeoutSeconds $waitTimeout -ExpectedIPAddress $expectedIp
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

# Blocklist: managed via the Proxy Admin web UI (port 8443).
# Squid reads this file on start and on 'squid -k reconfigure'.
acl blocklist dstdomain "/etc/squid/blocklist.txt"
http_access deny blocklist

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
    apt-get install -y squid ufw python3-flask
fi

install -d -m 0755 /etc/squid

# Create empty blocklist if it doesn't exist so Squid doesn't fail on start.
[ -f /etc/squid/blocklist.txt ] || touch /etc/squid/blocklist.txt
chmod 0644 /etc/squid/blocklist.txt
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

    $result = Invoke-LinuxVmCommand -VmName $vmName -IPAddress $ip -BashCommand $bash -Sudo -TimeoutSeconds 600 -DisplayName "Install Squid"
    if ($result.ScriptBlockFailed -or $result.ExitCode -ne 0) {
        Write-Log "[Proxy] $vmName`: Squid install failed (ExitCode=$($result.ExitCode))`n$($result.ScriptBlockOutput)" -Failure
        return $false
    }
    if ($result.ScriptBlockOutput -notmatch 'PROXY_READY') {
        Write-Log "[Proxy] $vmName`: Squid install did not report ready`n$($result.ScriptBlockOutput)" -Failure
        return $false
    }

    Write-Log "[Proxy] $vmName`: Squid listening on ${ip}:3128 (ACLs: $($subnets -join ', '))"

    # ---- Proxy Admin web UI ----
    # A lightweight Flask app that manages /etc/squid/blocklist.txt and
    # reloads Squid on changes. Runs as a systemd service on port 8443.
    $proxyAdminApp = @'
#!/usr/bin/env python3
"""memlabs Proxy Admin - Squid blocklist manager."""
import os, re, subprocess
from flask import Flask, request, redirect, url_for, Markup

app = Flask(__name__)
BLOCKLIST = "/etc/squid/blocklist.txt"

# Matches: domain names (.example.com, example.com), IPv4, IPv4/CIDR
_VALID_ENTRY = re.compile(
    r'^(?:'
    r'\.?[a-zA-Z0-9](?:[a-zA-Z0-9\-]*[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9\-]*[a-zA-Z0-9])?)*'
    r'|'
    r'\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(?:/\d{1,2})?'
    r')$'
)

def _read_blocklist():
    if not os.path.isfile(BLOCKLIST):
        return []
    with open(BLOCKLIST, "r") as f:
        return [line.strip() for line in f if line.strip() and not line.startswith("#")]

def _write_blocklist(entries):
    with open(BLOCKLIST, "w") as f:
        for e in sorted(set(entries)):
            f.write(e + "\n")
    subprocess.run(["squid", "-k", "reconfigure"], capture_output=True, timeout=10)

def _render(entries, error=None, success=None):
    rows = ""
    for e in entries:
        rows += (
            '<tr><td>{entry}</td><td>'
            '<form method="post" action="/delete" style="margin:0">'
            '<input type="hidden" name="entry" value="{entry}">'
            '<button type="submit" class="btn btn-sm btn-del">Remove</button>'
            '</form></td></tr>'
        ).format(entry=Markup.escape(e))
    if not entries:
        rows = '<tr><td colspan="2" class="empty">No entries — all traffic is allowed through Squid.</td></tr>'
    alert = ""
    if error:
        alert = '<div class="alert alert-error">{}</div>'.format(Markup.escape(error))
    if success:
        alert = '<div class="alert alert-ok">{}</div>'.format(Markup.escape(success))
    return '''<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Proxy Admin</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,system-ui,"Segoe UI",Roboto,sans-serif;background:#1e1e2e;color:#cdd6f4;min-height:100vh;padding:2rem}
h1{font-size:1.5rem;margin-bottom:.25rem;color:#89b4fa}
.subtitle{color:#6c7086;margin-bottom:1.5rem;font-size:.9rem}
.card{background:#313244;border-radius:8px;padding:1.25rem;margin-bottom:1.25rem;border:1px solid #45475a}
table{width:100%%;border-collapse:collapse}
th{text-align:left;padding:.5rem;border-bottom:2px solid #45475a;color:#89b4fa;font-size:.85rem;text-transform:uppercase;letter-spacing:.05em}
td{padding:.5rem;border-bottom:1px solid #45475a;font-family:"Cascadia Code",Consolas,monospace;font-size:.9rem}
.empty{color:#6c7086;font-style:italic;text-align:center;padding:1.5rem;font-family:inherit}
.add-form{display:flex;gap:.5rem}
.add-form input[type=text]{flex:1;padding:.5rem .75rem;border:1px solid #45475a;border-radius:6px;background:#1e1e2e;color:#cdd6f4;font-size:.9rem;font-family:"Cascadia Code",Consolas,monospace}
.add-form input[type=text]:focus{outline:none;border-color:#89b4fa}
.btn{padding:.4rem .75rem;border:none;border-radius:6px;cursor:pointer;font-size:.85rem;font-weight:500;transition:background .15s}
.btn-add{background:#a6e3a1;color:#1e1e2e}.btn-add:hover{background:#94e2d5}
.btn-del{background:#f38ba8;color:#1e1e2e}.btn-del:hover{background:#eba0ac}
.btn-sm{padding:.25rem .5rem;font-size:.8rem}
.alert{padding:.75rem 1rem;border-radius:6px;margin-bottom:1rem;font-size:.9rem}
.alert-error{background:#45475a;border:1px solid #f38ba8;color:#f38ba8}
.alert-ok{background:#45475a;border:1px solid #a6e3a1;color:#a6e3a1}
.help{color:#6c7086;font-size:.8rem;margin-top:.75rem}
</style></head><body>
<h1>Proxy Admin</h1>
<p class="subtitle">Squid blocklist manager &mdash; blocked domains and IPs are denied through the proxy.</p>
''' + alert + '''
<div class="card">
<form method="post" action="/add" class="add-form">
<input type="text" name="entry" placeholder=".example.com or 1.2.3.4 or 10.0.0.0/8" required autofocus>
<button type="submit" class="btn btn-add">Block</button>
</form>
<p class="help">Prefix with a dot to block all subdomains (e.g. <code>.windowsupdate.com</code> blocks <code>www.windowsupdate.com</code>). Plain domains block exact matches. IPv4 addresses and CIDR ranges also accepted.</p>
</div>
<div class="card">
<table><thead><tr><th>Blocked Entry</th><th style="width:100px">Action</th></tr></thead>
<tbody>''' + rows + '''</tbody></table>
</div>
</body></html>'''

@app.route("/")
def index():
    return _render(_read_blocklist(), success=request.args.get("ok"))

@app.route("/add", methods=["POST"])
def add():
    entry = (request.form.get("entry") or "").strip().lower()
    if not entry:
        return _render(_read_blocklist(), error="Entry cannot be empty.")
    if not _VALID_ENTRY.match(entry):
        return _render(_read_blocklist(), error="Invalid entry. Use a domain (.example.com), IP (1.2.3.4), or CIDR (10.0.0.0/8).")
    if len(entry) > 253:
        return _render(_read_blocklist(), error="Entry too long (max 253 characters).")
    entries = _read_blocklist()
    if entry in entries:
        return _render(entries, error="'{}' is already blocked.".format(entry))
    entries.append(entry)
    _write_blocklist(entries)
    return redirect(url_for("index", ok="Added '{}'.".format(entry)))

@app.route("/delete", methods=["POST"])
def delete():
    entry = (request.form.get("entry") or "").strip()
    entries = _read_blocklist()
    entries = [e for e in entries if e != entry]
    _write_blocklist(entries)
    return redirect(url_for("index", ok="Removed '{}'.".format(entry)))

@app.route("/health")
def health():
    return "ok", 200

if __name__ == "__main__":
    os.makedirs(os.path.dirname(BLOCKLIST), exist_ok=True)
    if not os.path.isfile(BLOCKLIST):
        open(BLOCKLIST, "a").close()
    app.run(host="0.0.0.0", port=8443)
'@

    $proxyAdminService = @'
[Unit]
Description=memlabs Proxy Admin Web UI
After=network.target squid.service
Wants=squid.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/memlabs/proxy-admin/app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
'@

    $appB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($proxyAdminApp))
    $svcB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($proxyAdminService))

    $webUiBash = @"
set -e

install -d -m 0755 /opt/memlabs/proxy-admin

NEW_APP=`$(mktemp)
echo '$appB64' | base64 -d > "`$NEW_APP"

APP_CHANGED=0
if [ -f /opt/memlabs/proxy-admin/app.py ] && cmp -s "`$NEW_APP" /opt/memlabs/proxy-admin/app.py; then
    rm -f "`$NEW_APP"
else
    mv "`$NEW_APP" /opt/memlabs/proxy-admin/app.py
    chmod 0755 /opt/memlabs/proxy-admin/app.py
    APP_CHANGED=1
fi

NEW_SVC=`$(mktemp)
echo '$svcB64' | base64 -d > "`$NEW_SVC"

SVC_CHANGED=0
if [ -f /etc/systemd/system/memlabs-proxy-admin.service ] && cmp -s "`$NEW_SVC" /etc/systemd/system/memlabs-proxy-admin.service; then
    rm -f "`$NEW_SVC"
else
    mv "`$NEW_SVC" /etc/systemd/system/memlabs-proxy-admin.service
    chmod 0644 /etc/systemd/system/memlabs-proxy-admin.service
    systemctl daemon-reload
    SVC_CHANGED=1
fi

systemctl enable memlabs-proxy-admin >/dev/null 2>&1 || true

if [ "`$APP_CHANGED" = "1" ] || [ "`$SVC_CHANGED" = "1" ] || ! systemctl is-active --quiet memlabs-proxy-admin; then
    systemctl restart memlabs-proxy-admin
fi

# Open 8443 in ufw
command -v ufw >/dev/null 2>&1 && ufw allow 8443/tcp || true

# Self-test: wait up to 10s for the web UI to start listening
for i in `$(seq 1 10); do
    if ss -ltn 'sport = :8443' 2>/dev/null | grep -q ':8443'; then
        echo WEBUI_READY
        exit 0
    fi
    sleep 1
done
echo 'proxy-admin not listening on 8443'
exit 1
"@

    $result2 = Invoke-LinuxVmCommand -VmName $vmName -IPAddress $ip -BashCommand $webUiBash -Sudo -TimeoutSeconds 120 -DisplayName "Install Proxy Admin UI"
    if ($result2.ScriptBlockFailed -or $result2.ExitCode -ne 0) {
        Write-Log "[Proxy] $vmName`: Proxy Admin web UI install failed (ExitCode=$($result2.ExitCode))`n$($result2.ScriptBlockOutput)" -Warning
        # Non-fatal: Squid is up, web UI is a convenience feature.
    }
    elseif ($result2.ScriptBlockOutput -notmatch 'WEBUI_READY') {
        Write-Log "[Proxy] $vmName`: Proxy Admin web UI did not report ready`n$($result2.ScriptBlockOutput)" -Warning
    }
    else {
        Write-Log "[Proxy] $vmName`: Proxy Admin web UI listening on ${ip}:8443"
    }

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

function Get-LinuxXrdpBashScript {
    <#
    .SYNOPSIS
        Bash body that installs xrdp + xfce4 + Firefox (Mozilla deb) and wires
        the default session. Idempotent: re-running after success is fast.

    .DESCRIPTION
        This used to live in the cloud-init seed ISO as a fragile sequence of
        YAML runcmd strings (each had to survive PS / YAML / bash quoting and
        a `Package: *` line tripped PyYAML's alias parser). Moved out of
        cloud-init into a Phase 3 SSH-driven step (Invoke-LinuxRoleConfiguration)
        so we can ship the whole thing as one base64-encoded bash file and stop
        fighting four nested quoting layers.

        Returns: [string] bash source. Assumes it will be run as root.
    #>
    [CmdletBinding()]
    param ()

    return @'
echo "[memlabs-rdp] start: $(date -Is)"
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
    xrdp xorgxrdp xfce4 xfce4-goodies dbus-x11 xorg \
    apt-transport-https ca-certificates gnupg wget

# xrdp drops privs to 'xrdp'; it needs to read the snakeoil key to TLS the handshake.
adduser xrdp ssl-cert || true

# Default XDG session for vmbuildadmin and root.
install -d -o vmbuildadmin -g vmbuildadmin -m 0755 /home/vmbuildadmin
echo 'xfce4-session' > /home/vmbuildadmin/.xsession
chown vmbuildadmin:vmbuildadmin /home/vmbuildadmin/.xsession
chmod 0644 /home/vmbuildadmin/.xsession
echo 'xfce4-session' > /root/.xsession
chmod 0644 /root/.xsession

# Pre-seed default xfce4 panel config so the "Welcome to the first start of
# the panel" dialog never fires. Over xrdp it renders behind the desktop or
# auto-dismisses with an empty panel, leaving a blank blue screen.
if [ -d /etc/xdg/xfce4/panel ]; then
    for UHOME in /home/vmbuildadmin /root; do
        install -d -o "$(stat -c '%U' "$UHOME")" -g "$(stat -c '%G' "$UHOME")" -m 0700 "$UHOME/.config"
        cp -rn /etc/xdg/xfce4 "$UHOME/.config/"
        chown -R "$(stat -c '%U' "$UHOME"):$(stat -c '%G' "$UHOME")" "$UHOME/.config/xfce4"
    done
fi

ufw allow 3389/tcp || true
systemctl enable --now xrdp || true
systemctl enable --now xrdp-sesman || true

# Firefox: the Ubuntu 'firefox' package is a snap shim that takes 30s+ to
# first-launch. Use the real Mozilla deb instead, pinned high so apt prefers
# it over the transitional snap stub.
install -d -m 0755 /etc/apt/keyrings
wget -qO- https://packages.mozilla.org/apt/repo-signing-key.gpg \
    | tee /etc/apt/keyrings/packages.mozilla.org.asc > /dev/null
echo 'deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main' \
    > /etc/apt/sources.list.d/mozilla.list
printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' \
    > /etc/apt/preferences.d/mozilla
apt-get update
apt-get install -y firefox

# Wire firefox as the system-wide x-www-browser / gnome-www-browser so
# xfce4-web-browser (which calls xdg-open -> x-www-browser) opens it.
update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/bin/firefox 200 || true
update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser /usr/bin/firefox 200 || true
update-alternatives --set x-www-browser /usr/bin/firefox || true
update-alternatives --set gnome-www-browser /usr/bin/firefox || true

# Tell XDG that firefox handles http/https/text-html system-wide.
install -d -m 0755 /etc/xdg
cat > /etc/xdg/mimeapps.list <<'MIMEEOF'
[Default Applications]
x-scheme-handler/http=firefox.desktop
x-scheme-handler/https=firefox.desktop
text/html=firefox.desktop
MIMEEOF

echo "[memlabs-rdp] done: $(date -Is)"
'@
}

function Get-LinuxClientBashScript {
    <#
    .SYNOPSIS
        Bash body that configures GNOME Desktop for LinuxClient VMs:
        .xsession for xrdp, Windows-like GNOME layout (Dash to Panel),
        Edge, Intune, and sensible lab defaults. Idempotent.

    .DESCRIPTION
        LinuxClient VMs use the UbuntuDesktop2404.vhdx base which has
        xrdp + GNOME + GDM3 baked in.  This Phase 3 script:
          1. Creates ~/.xsession so xrdp starts a GNOME session on X11
          2. Installs gnome-shell-extension-dash-to-panel (Windows taskbar)
          3. Applies dconf system defaults for a Windows-like layout:
             - Taskbar at bottom with Windows-style element positions
             - Minimize / maximize / close buttons on titlebars
             - Activities hot corner disabled
             - Screen lock & idle blank disabled (lab VM)
             - Welcome dialog suppressed
          4. Installs Microsoft Edge + Intune app from packages.microsoft.com
        Returns: [string] bash source.  Assumes it will be run as root.
    #>
    [CmdletBinding()]
    param ()

    return @'
echo "[memlabs-gnome] start: $(date -Is)"
export DEBIAN_FRONTEND=noninteractive

# --- .xsessionrc + .xsession: GNOME on X11 over xrdp ---------------------
# .xsessionrc is sourced by /etc/X11/Xsession BEFORE the session command
# runs, so env vars are available to gnome-session and all children.
# .xsession (non-executable, 0644) is read by Xsession's
# 50x11-common_determine-startup as the session command.
for UHOME in /home/vmbuildadmin /root; do
    UNAME=$(stat -c '%U' "$UHOME")
    UGRP=$(stat -c '%G' "$UHOME")

    cat > "$UHOME/.xsessionrc" << 'XSESSIONRC'
# memlabs: env vars for GNOME over xrdp (no hardware GPU)
export XDG_SESSION_TYPE=x11
export GDK_BACKEND=x11
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
# Mutter 46 refuses software renderers (llvmpipe) by default.
# xrdp has no GPU, so we must allow fallback drivers.
export MUTTER_ALLOW_FALLBACK_DRIVERS=1
export LIBGL_ALWAYS_SOFTWARE=1
XSESSIONRC
    chown "$UNAME:$UGRP" "$UHOME/.xsessionrc"
    chmod 0644 "$UHOME/.xsessionrc"

    # Session command — bare line, not executable, so Xsession runs it
    # via 'exec /bin/sh ~/.xsession' after all Xsession.d scripts.
    echo 'gnome-session --session=ubuntu' > "$UHOME/.xsession"
    chown "$UNAME:$UGRP" "$UHOME/.xsession"
    chmod 0644 "$UHOME/.xsession"
done

# --- Packages: dconf-cli + gnome-tweaks + Firefox prereqs ----------------
apt-get update
apt-get install -y \
    gnome-tweaks \
    dconf-cli \
    unzip \
    apt-transport-https ca-certificates gnupg wget

# --- dash-to-panel: install from extensions.gnome.org --------------------
# Not packaged in Ubuntu 24.04 repos (GNOME 46 was too new at Noble freeze).
# Query the API for the download URL matching the installed GNOME Shell.
EXT_UUID="dash-to-panel@jderose9.github.com"
SHELL_VER=$(gnome-shell --version 2>/dev/null | grep -oP '[\d.]+' | cut -d. -f1)
if [ -n "$SHELL_VER" ]; then
    DL_URL=$(wget -qO- "https://extensions.gnome.org/extension-info/?uuid=${EXT_UUID}&shell_version=${SHELL_VER}" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['download_url'])" 2>/dev/null)
    if [ -n "$DL_URL" ]; then
        wget -qO /tmp/dash-to-panel.zip "https://extensions.gnome.org${DL_URL}"
        install -d -m 0755 "/usr/share/gnome-shell/extensions/${EXT_UUID}"
        unzip -o /tmp/dash-to-panel.zip -d "/usr/share/gnome-shell/extensions/${EXT_UUID}/"
        chmod -R a+rX "/usr/share/gnome-shell/extensions/${EXT_UUID}"
        rm -f /tmp/dash-to-panel.zip
        echo "[memlabs-gnome] dash-to-panel installed from extensions.gnome.org (shell ${SHELL_VER})"
    else
        echo "[memlabs-gnome] WARNING: could not resolve dash-to-panel download URL for GNOME ${SHELL_VER}" >&2
    fi
else
    echo "[memlabs-gnome] WARNING: could not detect GNOME Shell version" >&2
fi

# --- Polkit: allow colord without auth for xrdp sessions ------------------
# Without this rule xrdp logins trigger a "color managed device" auth dialog.
install -d -m 0755 /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/45-allow-colord.rules << 'RULES'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.color-manager.") == 0) {
        return polkit.Result.YES;
    }
});
RULES

# --- dconf: Windows-like GNOME defaults (system-wide) --------------------
# Uses the 'local' system-db which is Ubuntu desktop's default.
install -d -m 0755 /etc/dconf/profile
if ! [ -f /etc/dconf/profile/user ] || ! grep -q 'system-db:local' /etc/dconf/profile/user 2>/dev/null; then
    printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
fi

install -d -m 0755 /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/01-memlabs-windows-like << 'DCONF'
# ── Windows-like GNOME defaults ── memlabs LinuxClient ──

# Minimize + maximize buttons  (left: app-menu │ right: min, max, close)
[org/gnome/desktop/wm/preferences]
button-layout='appmenu:minimize,maximize,close'

# Enable extensions + pin Edge (not Firefox) to the dash/taskbar
[org/gnome/shell]
enabled-extensions=['dash-to-panel@jderose9.github.com', 'ding@rastersoft.com']
welcome-dialog-last-shown-version='99.0'
favorite-apps=['microsoft-edge.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Terminal.desktop', 'org.gnome.TextEditor.desktop']

# Dash-to-panel: taskbar at bottom, Windows 10/11 style
#   Left:   Show Apps (≈ Start), Left Box
#   Center: Taskbar (running windows)
#   Right:  System tray, Date/Time, System Menu, Show Desktop button
[org/gnome/shell/extensions/dash-to-panel]
panel-positions='{"0":"BOTTOM"}'
panel-sizes='{"0":40}'
panel-element-positions='{"0":[{"element":"showAppsButton","visible":true,"position":"stackedTL"},{"element":"activitiesButton","visible":false,"position":"stackedTL"},{"element":"leftBox","visible":true,"position":"stackedTL"},{"element":"taskbar","visible":true,"position":"centerMonitor"},{"element":"centerBox","visible":false,"position":"stackedBR"},{"element":"rightBox","visible":true,"position":"stackedBR"},{"element":"dateMenu","visible":true,"position":"stackedBR"},{"element":"systemMenu","visible":true,"position":"stackedBR"},{"element":"desktopButton","visible":true,"position":"stackedBR"}]}'
appicon-margin=4
appicon-padding=4
animate-appicon-hover=false
dot-style-focused='DASHES'
dot-style-unfocused='DOTS'
trans-use-custom-opacity=false
hide-overview-on-startup=true
show-apps-icon-file=''

# Disable Activities hot-corner
[org/gnome/desktop/interface]
enable-hot-corners=false

# Desktop icons (Home + Trash)
[org/gnome/shell/extensions/ding]
show-home=true
show-trash=true

# No screen lock / idle blank (lab VM, not production)
[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/desktop/screensaver]
lock-enabled=false

[org/gnome/desktop/notifications]
show-banners=true
DCONF

dconf update

# --- Microsoft Edge: Intune enrollment requires Edge 102+ ----------------
install -d -m 0755 /etc/apt/keyrings
wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor | tee /etc/apt/keyrings/microsoft.gpg > /dev/null
echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/edge stable main' \
    > /etc/apt/sources.list.d/microsoft-edge.list
apt-get update
apt-get install -y microsoft-edge-stable

# Wire Edge as default browser system-wide.
update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/bin/microsoft-edge-stable 200 || true
update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser /usr/bin/microsoft-edge-stable 200 || true
update-alternatives --set x-www-browser /usr/bin/microsoft-edge-stable || true
update-alternatives --set gnome-www-browser /usr/bin/microsoft-edge-stable || true

install -d -m 0755 /etc/xdg
cat > /etc/xdg/mimeapps.list << 'MIMEEOF'
[Default Applications]
x-scheme-handler/http=microsoft-edge.desktop
x-scheme-handler/https=microsoft-edge.desktop
text/html=microsoft-edge.desktop
MIMEEOF

# --- Microsoft Intune app (intune-portal) --------------------------------
# Uses the same Microsoft signing key already imported above.
echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/24.04/prod noble main' \
    > /etc/apt/sources.list.d/microsoft-prod.list
apt-get update
apt-get install -y intune-portal

# --- Per-user fixup: replace Firefox with Edge in taskbar favorites -------
# System-wide dconf defaults only apply to keys the user hasn't set yet.
# Once a user logs in, GNOME writes per-user favorite-apps (including
# firefox.desktop from Ubuntu's default). Patch every existing user's
# dconf database so Edge replaces Firefox in the taskbar on next login.
for UHOME in /home/vmbuildadmin /root; do
    UNAME=$(stat -c '%U' "$UHOME" 2>/dev/null) || continue
    # dbus-launch + dconf requires the user's XDG_RUNTIME_DIR; using
    # gsettings/dconf as root with DCONF_PROFILE won't write to the
    # per-user db. Instead, use the dconf CLI under su.
    if [ -d "$UHOME/.config/dconf" ]; then
        su - "$UNAME" -c "
            export DCONF_PROFILE=/etc/dconf/profile/user
            CURRENT=\$(dconf read /org/gnome/shell/favorite-apps 2>/dev/null)
            if echo \"\$CURRENT\" | grep -q 'firefox.desktop'; then
                NEW=\$(echo \"\$CURRENT\" | sed \"s/'firefox.desktop'/'microsoft-edge.desktop'/g\")
                dconf write /org/gnome/shell/favorite-apps \"\$NEW\"
                echo '[memlabs-gnome] replaced firefox with edge in favorite-apps for $UNAME'
            elif [ -z \"\$CURRENT\" ] || [ \"\$CURRENT\" = \"@as []\" ]; then
                dconf write /org/gnome/shell/favorite-apps \"['microsoft-edge.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Terminal.desktop', 'org.gnome.TextEditor.desktop']\"
                echo '[memlabs-gnome] set favorite-apps with edge for $UNAME'
            fi
        " || true
    fi
done

echo "[memlabs-gnome] done: $(date -Is)"
'@
}

function Get-LinuxRealmJoinBashScript {
    <#
    .SYNOPSIS
        Bash body that installs realmd + sssd stack and joins the lab AD.

    .DESCRIPTION
        Extracted from Get-LinuxDomainJoinSeedArgs so the same script can run
        from Phase 3 SSH dispatch instead of cloud-init. Caller supplies
        $Domain (lowercase), $DcIp, $AdminUser, $AdminPassword. We
        single-quote-escape the password into bash. Returns [string] bash.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Domain,
        [Parameter(Mandatory = $true)][string]$DcIp,
        [Parameter(Mandatory = $true)][string]$AdminUser,
        [Parameter(Mandatory = $true)][string]$AdminPassword
    )

    $pwBashSingle = $AdminPassword -replace "'", "'\''"
    $domainLower = $Domain.ToLower()

    return @"
echo "[memlabs-realm-join] start: `$(date -Is)"
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y realmd sssd sssd-tools adcli krb5-user packagekit \
    samba-common-bin oddjob oddjob-mkhomedir libnss-sss libpam-sss

DOMAIN='$domainLower'
DC_IP='$dcIp'
ADMIN_USER='$AdminUser'
ADMIN_PWD='$pwBashSingle'

/usr/local/sbin/memlabs-set-dns "`$DC_IP" "`$DOMAIN" || true

for i in {1..80}; do
  if getent hosts "`$DOMAIN" >/dev/null 2>&1; then break; fi
  echo "[memlabs-realm-join] waiting for DNS on `$DOMAIN (attempt `$i/80)"
  sleep 15
done

realm discover "`$DOMAIN" || true

JOINED=0
for i in {1..5}; do
  if echo "`$ADMIN_PWD" | realm join -U "`$ADMIN_USER" "`$DOMAIN" --install=/; then
    JOINED=1
    break
  fi
  echo "[memlabs-realm-join] attempt `$i failed, retry in 30s"
  sleep 30
done

if [ "`$JOINED" != "1" ]; then
  echo "[memlabs-realm-join] ERROR: all join attempts failed"
  exit 1
fi

realm permit --realm "`$DOMAIN" --all || true
sed -i 's/^use_fully_qualified_names = .*/use_fully_qualified_names = False/' /etc/sssd/sssd.conf || true
sed -i 's|^fallback_homedir = .*|fallback_homedir = /home/%u|' /etc/sssd/sssd.conf || true
pam-auth-update --enable mkhomedir || true
systemctl restart sssd || true

echo '%domain\ admins ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/memlabs-domain-admins
chmod 0440 /etc/sudoers.d/memlabs-domain-admins

echo "[memlabs-realm-join] done: `$(date -Is)"
"@
}

function Invoke-LinuxRoleConfiguration {
    <#
    .SYNOPSIS
        Phase 3 entrypoint for Linux VMs. Applies role-driven post-boot config
        (xrdp/Firefox/realm-join) over SSH so cloud-init can stay minimal.

    .DESCRIPTION
        Decides which bash modules apply based on VM flags:
          - enableRDP=true       -> Get-LinuxXrdpBashScript
          - role='LinuxClient'   -> Get-LinuxClientBashScript
          - joinDomain=true      -> Get-LinuxRealmJoinBashScript
        Concatenates the modules into a single bash script, base64-encodes it,
        and ships via one Invoke-LinuxVmCommand call. No-op (success) when no
        modules apply.

        Mirrors Install-LinuxProxyServer's contract: returns [bool]. Best-effort
        logging on failure; never throws.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][object]$Vm,
        [Parameter(Mandatory = $true)][object]$DeployConfig
    )

    $vmName  = $Vm.vmName
    $role    = $Vm.role
    $activity = "$vmName [$role]"

    # Build ordered list of operations. Each entry: Name (short id), Label
    # (human-readable, surfaced in Phase 3 row), Script (bash), TimeoutSec,
    # Tag (short DisplayName for the SSH wrapper / guest log).
    $ops = New-Object System.Collections.Generic.List[object]

    if ($Vm.PSObject.Properties.Name -contains 'enableRDP' -and [bool]$Vm.enableRDP) {
        $ops.Add([pscustomobject]@{
            Name       = 'enableRDP'
            Label      = 'Installing XRDP + xfce4 + Firefox'
            Script     = (Get-LinuxXrdpBashScript)
            TimeoutSec = 1800
            Tag        = 'memlabs-xrdp'
        })
    }

    # LinuxClient: GNOME Desktop with xrdp baked in; needs .xsession +
    # Windows-like GNOME tweaks + Edge + Intune.  No enableRDP toggle -- xrdp is
    # always-on for this role (it's the whole point of a Desktop image).
    if ($role -eq 'LinuxClient') {
        $ops.Add([pscustomobject]@{
            Name       = 'gnomeDesktop'
            Label      = 'Configuring GNOME desktop (Windows-like layout + Edge + Intune)'
            Script     = (Get-LinuxClientBashScript)
            TimeoutSec = 1800
            Tag        = 'memlabs-gnome'
        })
    }

    if ($Vm.PSObject.Properties.Name -contains 'joinDomain' -and [bool]$Vm.joinDomain) {
        $netBase = $Vm.network
        if (-not $netBase) { $netBase = $DeployConfig.vmOptions.network }
        $adminUser = $DeployConfig.vmOptions.adminName
        $domain    = $DeployConfig.vmOptions.domainName
        $adminPwd  = $null
        if ($Common -and $Common.LocalAdmin) {
            try { $adminPwd = $Common.LocalAdmin.GetNetworkCredential().Password } catch { $adminPwd = $null }
        }
        if (-not ($netBase -match '^(\d+\.\d+\.\d+)\.\d+$')) {
            Write-Log "[LinuxConfig] $vmName`: network '$netBase' isn't /24 a.b.c.0 form; skipping realm-join" -Warning
        }
        elseif (-not $adminUser -or -not $adminPwd -or -not $domain) {
            Write-Log "[LinuxConfig] $vmName`: missing adminName/LocalAdmin/domain; skipping realm-join" -Warning
        }
        else {
            $dcIp = "$($Matches[1]).1"
            $ops.Add([pscustomobject]@{
                Name       = 'joinDomain'
                Label      = "Joining AD domain $domain"
                Script     = (Get-LinuxRealmJoinBashScript -Domain $domain -DcIp $dcIp -AdminUser $adminUser -AdminPassword $adminPwd)
                TimeoutSec = 1800
                Tag        = 'memlabs-realm-join'
            })
        }
    }

    if ($ops.Count -eq 0) {
        Write-Log "[LinuxConfig] $vmName`: no role-driven config applies; nothing to do."
        return $true
    }

    Write-Log "[LinuxConfig] $vmName`: applying $($ops.Count) module(s): $(($ops | ForEach-Object Name) -join ', ')"

    # Wait for SSH first; the VM may have rebooted between phases.
    Write-Progress2 -Activity $activity -Status "Waiting for SSH" -force
    $expectedIp  = Get-LinuxVmExpectedStaticIP -VmObject $Vm -DeployConfig $DeployConfig
    $waitTimeout = Get-LinuxVmWaitTimeout -VmObject $Vm
    $ip = Wait-LinuxVmReady -VmName $vmName -TimeoutSeconds $waitTimeout -ExpectedIPAddress $expectedIp
    if (-not $ip) {
        Write-Log "[LinuxConfig] $vmName`: VM not SSH-reachable; cannot apply config." -Failure
        return $false
    }

    # Run each module as its own SSH invocation so the Phase 3 row reflects
    # exactly what's running. Fail-fast: a module failure aborts subsequent
    # modules and returns $false (matches the old single-blob behavior).
    $i = 0
    foreach ($op in $ops) {
        $i++
        $statusText = "[$i/$($ops.Count)] $($op.Label)"
        Write-Progress2 -Activity $activity -Status $statusText -force
        Write-Log "[Phase 3]: $vmName`: $statusText" -OutputStream

        # Wrap in `set -e` so any failed command inside the module aborts the
        # module (and the whole script) with non-zero exit; mirrors the old
        # outer-loop pipefail behavior.
        $script = "#!/bin/bash`nset -euo pipefail`n" + $op.Script + "`n"
        $scriptLf = $script -replace "`r`n", "`n"
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($scriptLf))
        $bash = "echo $b64 | base64 -d > /root/$($op.Tag).sh && chmod 0700 /root/$($op.Tag).sh && /root/$($op.Tag).sh"

        $result = Invoke-LinuxVmCommand -VmName $vmName -IPAddress $ip -BashCommand $bash -Sudo -DisplayName $op.Tag -TimeoutSeconds $op.TimeoutSec
        if (-not ($result -and $result.CommandResult)) {
            $tail = $null
            if ($result -and $result.ScriptBlockOutput) {
                $lines = ($result.ScriptBlockOutput -split "`n")
                $tail = ($lines | Select-Object -Last 20) -join "`n"
            }
            Write-Log "[LinuxConfig] $vmName`: module '$($op.Name)' FAILED (exit=$($result.ExitCode)). Tail:`n$tail" -Failure
            return $false
        }
        Write-Log "[Phase 3]: $vmName`: $($op.Label) complete." -Success
    }

    Write-Log "[LinuxConfig] $vmName`: configuration complete ($(($ops | ForEach-Object Name) -join ', '))." -Success
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
            # Helper: build and write the DefaultConnectionSettings binary blob
            # under the given Internet Settings registry path. This is what
            # WinHttpGetIEProxyConfigForCurrentUser() (and therefore Edge/Chrome)
            # actually reads. The classic ProxyEnable/ProxyServer/ProxyOverride
            # keys are a separate, independent store that Edge ignores.
            $writeConnBlob = {
                param([string]$ieRegPath, [string]$proxy, [string]$bypass, [bool]$enable)
                $connPath = Join-Path $ieRegPath 'Connections'
                if (-not (Test-Path $connPath)) { New-Item -Path $connPath -Force | Out-Null }
                $old = (Get-ItemProperty -Path $connPath -Name 'DefaultConnectionSettings' -EA SilentlyContinue).DefaultConnectionSettings
                $ctr = if ($old -and $old.Length -ge 4) { [BitConverter]::ToUInt32($old, 0) + 1 } else { 46 }
                if ($enable) {
                    $pB = [Text.Encoding]::ASCII.GetBytes($proxy)
                    $bB = [Text.Encoding]::ASCII.GetBytes($bypass)
                    $fl = [uint32]0x03  # present + proxy enabled
                } else {
                    $pB = [byte[]]@(); $bB = [byte[]]@()
                    $fl = [uint32]0x09  # present + auto-detect (Windows default)
                }
                $blob = New-Object byte[] (4+4+4+$pB.Length+4+$bB.Length+4+32)
                $o = 0
                [Array]::Copy([BitConverter]::GetBytes([uint32]$ctr), 0, $blob, $o, 4); $o += 4
                [Array]::Copy([BitConverter]::GetBytes($fl), 0, $blob, $o, 4); $o += 4
                [Array]::Copy([BitConverter]::GetBytes([uint32]$pB.Length), 0, $blob, $o, 4); $o += 4
                if ($pB.Length) { [Array]::Copy($pB, 0, $blob, $o, $pB.Length); $o += $pB.Length }
                [Array]::Copy([BitConverter]::GetBytes([uint32]$bB.Length), 0, $blob, $o, 4); $o += 4
                if ($bB.Length) { [Array]::Copy($bB, 0, $blob, $o, $bB.Length); $o += $bB.Length }
                # auto-config URL length = 0, remaining 32 bytes = zero padding
                Set-ItemProperty -Path $connPath -Name 'DefaultConnectionSettings' -Value $blob -Type Binary -Force
            }

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

            # 3a-hkcu) Per-user HKCU + all loaded user hives under HKU.
            #    Edge/Chrome (Chromium) resolves proxy via
            #    WinHttpGetIEProxyConfigForCurrentUser(), which reads HKCU
            #    regardless of the ProxySettingsPerUser policy above (that
            #    policy only affects WinINET-based apps like legacy IE).
            #    Without this, Edge has no proxy configured, traffic goes
            #    direct, TCP/UDP 443 is ACL-denied, and browsing fails.
            #    Set HKCU for the PSDirect admin session (persists for
            #    interactive logon) plus sweep all loaded user SIDs.
            $hkcuKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
            New-ItemProperty -Path $hkcuKey -Name 'ProxyEnable' -PropertyType DWord -Value 1 -Force | Out-Null
            New-ItemProperty -Path $hkcuKey -Name 'ProxyServer' -PropertyType String -Value $proxyServer -Force | Out-Null
            New-ItemProperty -Path $hkcuKey -Name 'ProxyOverride' -PropertyType String -Value $bypassList -Force | Out-Null

            # Sweep all loaded user hives (S-1-5-21-*) so any other logged-in
            # user or previously-loaded profile also gets the proxy.
            $userSids = Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -match '^S-1-5-21-' -and $_.PSChildName -notmatch '_Classes$' }
            foreach ($sid in $userSids) {
                $userIeKey = "Registry::HKEY_USERS\$($sid.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
                if (-not (Test-Path $userIeKey)) { continue }
                New-ItemProperty -Path $userIeKey -Name 'ProxyEnable' -PropertyType DWord -Value 1 -Force | Out-Null
                New-ItemProperty -Path $userIeKey -Name 'ProxyServer' -PropertyType String -Value $proxyServer -Force | Out-Null
                New-ItemProperty -Path $userIeKey -Name 'ProxyOverride' -PropertyType String -Value $bypassList -Force | Out-Null
                & $writeConnBlob $userIeKey $proxyServer $bypassList $true
            }

            # 3a-conn) DefaultConnectionSettings blobs for HKCU + HKLM.
            #    Edge/Chrome calls WinHttpGetIEProxyConfigForCurrentUser()
            #    which reads the DefaultConnectionSettings binary blob under
            #    ...\Internet Settings\Connections — NOT the classic
            #    ProxyEnable/ProxyServer/ProxyOverride keys written above.
            #    Without this blob, the Windows Settings > Proxy UI shows
            #    "Off" and Edge goes direct despite the classic keys being set.
            & $writeConnBlob $hkcuKey $proxyServer $bypassList $true
            & $writeConnBlob $ieKey  $proxyServer $bypassList $true

            # 3b) Edge browser policy (HKLM\SOFTWARE\Policies\Microsoft\Edge).
            #     Edge reads managed proxy settings from this policy key before
            #     falling back to WinINET / DefaultConnectionSettings. Setting
            #     ProxyMode=fixed_servers here guarantees Edge uses the proxy
            #     regardless of whether the DefaultConnectionSettings blob is
            #     being picked up by WinHttpGetIEProxyConfigForCurrentUser().
            $edgePolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
            if (-not (Test-Path $edgePolicyKey)) { New-Item -Path $edgePolicyKey -Force | Out-Null }
            New-ItemProperty -Path $edgePolicyKey -Name 'ProxyMode'       -PropertyType String -Value 'fixed_servers'      -Force | Out-Null
            New-ItemProperty -Path $edgePolicyKey -Name 'ProxyServer'     -PropertyType String -Value "http://$proxyServer" -Force | Out-Null
            New-ItemProperty -Path $edgePolicyKey -Name 'ProxyBypassList' -PropertyType String -Value $bypassList           -Force | Out-Null

            # 3c) HKLM Wow6432Node IE settings -- the 32-bit registry view.
            #     Internet Settings is NOT redirected by WOW64, but some
            #     32-bit installers (notably adksetup.exe, a 32-bit WiX Burn
            #     bundle) explicitly read from Wow6432Node first. Without
            #     this, the ADK bootstrapper bypasses the proxy and hits the
            #     host's broken egress, failing with "dead fwlink" download
            #     errors. Mirror the 64-bit values here so 32-bit consumers
            #     see the same proxy config.
            $ieKeyWow = 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Internet Settings'
            if (-not (Test-Path $ieKeyWow)) { New-Item -Path $ieKeyWow -Force | Out-Null }
            New-ItemProperty -Path $ieKeyWow -Name 'ProxyEnable' -PropertyType DWord -Value 1 -Force | Out-Null
            New-ItemProperty -Path $ieKeyWow -Name 'ProxyServer' -PropertyType String -Value $proxyServer -Force | Out-Null
            New-ItemProperty -Path $ieKeyWow -Name 'ProxyOverride' -PropertyType String -Value $bypassList -Force | Out-Null

            # 4) HKU\.DEFAULT IE settings -- this is what SYSTEM context reads.
            #    .NET WebClient / HttpWebRequest (used by DSC scripts running as
            #    LocalSystem) resolves its default proxy via
            #    WinHttpGetIEProxyConfigForCurrentUser, which for SYSTEM returns
            #    HKU\.DEFAULT, NOT the HKLM keys above (ProxySettingsPerUser=0
            #    only affects WinINet, not .NET's resolver). Without this,
            #    DSC downloads (e.g. InstallODBCDriver fetching msodbcsql.msi
            #    via WebClient) bypass the proxy entirely and hit the ACL
            #    deny rule with "Unable to connect to the remote server".
            #    (Step 3a-hkcu above already swept loaded S-1-5-21-* hives;
            #    .DEFAULT is S-1-5-18 which that sweep skips, so set it
            #    explicitly.)
            $defaultUserKey = 'Registry::HKEY_USERS\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
            if (-not (Test-Path $defaultUserKey)) { New-Item -Path $defaultUserKey -Force | Out-Null }
            New-ItemProperty -Path $defaultUserKey -Name 'ProxyEnable' -PropertyType DWord -Value 1 -Force | Out-Null
            New-ItemProperty -Path $defaultUserKey -Name 'ProxyServer' -PropertyType String -Value $proxyServer -Force | Out-Null
            New-ItemProperty -Path $defaultUserKey -Name 'ProxyOverride' -PropertyType String -Value $bypassList -Force | Out-Null
            & $writeConnBlob $defaultUserKey $proxyServer $bypassList $true

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


function Remove-WindowsClientProxy {
    <#
    .SYNOPSIS
        Remove proxy configuration from a Windows VM, restoring direct
        Internet access.

    .DESCRIPTION
        Reverse of Set-WindowsClientProxy. Run remotely on the target VM
        via Invoke-VmCommand. Clears every proxy layer that
        Set-WindowsClientProxy configures:
          - WinHTTP system proxy (netsh winhttp reset proxy)
          - Machine-wide HTTP_PROXY / HTTPS_PROXY / NO_PROXY env vars
          - HKLM proxy policy (ProxySettingsPerUser)
          - HKLM IE proxy keys (64-bit + Wow6432Node)
          - HKU\.DEFAULT IE proxy keys
          - .NET Framework machine.config <defaultProxy> element

        Idempotent. Safe to call on a VM that was never proxied.

    .PARAMETER VmName
        Target Windows VM name (PSDirect-reachable).

    .PARAMETER Domain
        Active Directory domain (used for PSDirect creds).

    .OUTPUTS
        [bool] $true on success, $false on failure (logged).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [string]$VmName,
        [Parameter(Mandatory = $true)] [string]$Domain
    )

    $scriptBlock = {
        $ErrorActionPreference = 'Stop'
        try {
            # Helper: reset DefaultConnectionSettings blob (same as Set function)
            $writeConnBlob = {
                param([string]$ieRegPath, [string]$proxy, [string]$bypass, [bool]$enable)
                $connPath = Join-Path $ieRegPath 'Connections'
                if (-not (Test-Path $connPath)) { return }
                $old = (Get-ItemProperty -Path $connPath -Name 'DefaultConnectionSettings' -EA SilentlyContinue).DefaultConnectionSettings
                $ctr = if ($old -and $old.Length -ge 4) { [BitConverter]::ToUInt32($old, 0) + 1 } else { 46 }
                if ($enable) {
                    $pB = [Text.Encoding]::ASCII.GetBytes($proxy)
                    $bB = [Text.Encoding]::ASCII.GetBytes($bypass)
                    $fl = [uint32]0x03
                } else {
                    $pB = [byte[]]@(); $bB = [byte[]]@()
                    $fl = [uint32]0x09
                }
                $blob = New-Object byte[] (4+4+4+$pB.Length+4+$bB.Length+4+32)
                $o = 0
                [Array]::Copy([BitConverter]::GetBytes([uint32]$ctr), 0, $blob, $o, 4); $o += 4
                [Array]::Copy([BitConverter]::GetBytes($fl), 0, $blob, $o, 4); $o += 4
                [Array]::Copy([BitConverter]::GetBytes([uint32]$pB.Length), 0, $blob, $o, 4); $o += 4
                if ($pB.Length) { [Array]::Copy($pB, 0, $blob, $o, $pB.Length); $o += $pB.Length }
                [Array]::Copy([BitConverter]::GetBytes([uint32]$bB.Length), 0, $blob, $o, 4); $o += 4
                if ($bB.Length) { [Array]::Copy($bB, 0, $blob, $o, $bB.Length); $o += $bB.Length }
                Set-ItemProperty -Path $connPath -Name 'DefaultConnectionSettings' -Value $blob -Type Binary -Force
            }

            # 1) WinHTTP
            & netsh winhttp reset proxy | Out-Null

            # 2) Machine-wide env vars
            [Environment]::SetEnvironmentVariable('HTTP_PROXY', $null, 'Machine')
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $null, 'Machine')
            [Environment]::SetEnvironmentVariable('NO_PROXY', $null, 'Machine')

            # 3) HKLM proxy policy
            $policyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'
            if (Test-Path $policyKey) {
                Remove-ItemProperty -Path $policyKey -Name 'ProxySettingsPerUser' -ErrorAction SilentlyContinue
            }

            # 3a) HKLM IE settings (64-bit)
            $ieKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
            New-ItemProperty -Path $ieKey -Name 'ProxyEnable' -PropertyType DWord -Value 0 -Force | Out-Null
            Remove-ItemProperty -Path $ieKey -Name 'ProxyServer' -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $ieKey -Name 'ProxyOverride' -ErrorAction SilentlyContinue
            & $writeConnBlob $ieKey '' '' $false

            # 3a-edge) Edge browser policy
            $edgePolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
            if (Test-Path $edgePolicyKey) {
                Remove-ItemProperty -Path $edgePolicyKey -Name 'ProxyMode'       -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $edgePolicyKey -Name 'ProxyServer'     -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $edgePolicyKey -Name 'ProxyBypassList' -ErrorAction SilentlyContinue
            }

            # 3b) HKLM Wow6432Node IE settings (32-bit view)
            $ieKeyWow = 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Internet Settings'
            if (Test-Path $ieKeyWow) {
                New-ItemProperty -Path $ieKeyWow -Name 'ProxyEnable' -PropertyType DWord -Value 0 -Force | Out-Null
                Remove-ItemProperty -Path $ieKeyWow -Name 'ProxyServer' -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $ieKeyWow -Name 'ProxyOverride' -ErrorAction SilentlyContinue
            }

            # 4) HKU\.DEFAULT IE settings
            $defaultUserKey = 'Registry::HKEY_USERS\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
            if (Test-Path $defaultUserKey) {
                New-ItemProperty -Path $defaultUserKey -Name 'ProxyEnable' -PropertyType DWord -Value 0 -Force | Out-Null
                Remove-ItemProperty -Path $defaultUserKey -Name 'ProxyServer' -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $defaultUserKey -Name 'ProxyOverride' -ErrorAction SilentlyContinue
                & $writeConnBlob $defaultUserKey '' '' $false
            }

            # 4a) HKCU + all loaded user hives (reverse of Set step 3a-hkcu)
            $hkcuKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
            if (Test-Path $hkcuKey) {
                New-ItemProperty -Path $hkcuKey -Name 'ProxyEnable' -PropertyType DWord -Value 0 -Force | Out-Null
                Remove-ItemProperty -Path $hkcuKey -Name 'ProxyServer' -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $hkcuKey -Name 'ProxyOverride' -ErrorAction SilentlyContinue
                & $writeConnBlob $hkcuKey '' '' $false
            }
            $userSids = Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -match '^S-1-5-21-' -and $_.PSChildName -notmatch '_Classes$' }
            foreach ($sid in $userSids) {
                $userIeKey = "Registry::HKEY_USERS\$($sid.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
                if (-not (Test-Path $userIeKey)) { continue }
                New-ItemProperty -Path $userIeKey -Name 'ProxyEnable' -PropertyType DWord -Value 0 -Force | Out-Null
                Remove-ItemProperty -Path $userIeKey -Name 'ProxyServer' -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $userIeKey -Name 'ProxyOverride' -ErrorAction SilentlyContinue
                & $writeConnBlob $userIeKey '' '' $false
            }

            # 5) .NET Framework machine.config <defaultProxy>
            $machineConfigPaths = @(
                "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\Config\machine.config",
                "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\Config\machine.config"
            )
            foreach ($mcPath in $machineConfigPaths) {
                if (-not (Test-Path $mcPath)) { continue }
                $xml = [xml](Get-Content -LiteralPath $mcPath -Raw)
                $existing = $xml.DocumentElement.SelectSingleNode('system.net/defaultProxy')
                if ($existing) {
                    [void]$existing.ParentNode.RemoveChild($existing)
                    $xml.Save($mcPath)
                }
            }

            # Force WMI provider hosts to reload machine.config
            try {
                Get-Process WmiPrvSE -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Get-Process WmiApSrv -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            } catch { }

            $current = & netsh winhttp show proxy
            return @{ Ok = $true; WinHttp = ($current -join "`n") }
        }
        catch {
            return @{ Ok = $false; Error = $_.ToString() }
        }
    }

    $result = Invoke-VmCommand -VmName $VmName -VmDomainName $Domain `
        -ScriptBlock $scriptBlock `
        -DisplayName "Remove proxy config"
    if ($result.ScriptBlockFailed) {
        Write-Log "[Proxy] $VmName`: Remove-WindowsClientProxy ScriptBlockFailed: $($result.ScriptBlockOutput)" -Failure
        return $false
    }
    $payload = $result.ScriptBlockOutput
    if (-not $payload -or -not $payload.Ok) {
        Write-Log "[Proxy] $VmName`: Remove-WindowsClientProxy failed: $($payload.Error)" -Failure
        return $false
    }
    Write-Log "[Proxy] $VmName`: Proxy configuration removed (direct access)"
    return $true
}


function Remove-WindowsClientProxyForDomain {
    <#
    .SYNOPSIS
        Remove proxy configuration from all opted-in Windows VMs in a
        domain and clear their Hyper-V enforcement ACLs.

    .DESCRIPTION
        Enumerates deployed VMs in the domain via Get-List, filters to
        those with useProxy=true in VM Notes, then for each:
          1. Calls Remove-WindowsClientProxy (in-guest unconfiguration)
          2. Calls Clear-VmProxyEnforcement (host-side ACL cleanup)
          3. Updates the VM Note: useProxy = false

        When -VmName is specified, only that single VM is processed
        (used for removing proxy from an individual host).

        Skips VMs that are not running (logs a warning, still updates
        the VM Note and clears ACLs since those are host-side).

    .PARAMETER DomainName
        The AD domain whose VMs should be unconfigured.

    .PARAMETER VmName
        Optional. Process only this single VM instead of the full domain.

    .OUTPUTS
        [bool] $true if all VMs succeeded, $false if any failed.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]  [string]$DomainName,
        [Parameter(Mandatory = $false)] [string]$VmName
    )

    $allVms = @(Get-List -Type VM -DomainName $DomainName)
    $hardExclude = @('Proxy', 'DC', 'BDC', 'StandaloneRootCA')

    $clients = @($allVms | Where-Object {
        $_.vmName -and
        $_.role -notin $hardExclude -and
        (-not (Test-VmIsLinux -Vm $_)) -and
        $_.PSObject.Properties.Name -contains 'useProxy' -and
        [bool]$_.useProxy
    })

    if ($VmName) {
        $clients = @($clients | Where-Object { $_.vmName -eq $VmName })
    }

    if (-not $clients -or $clients.Count -eq 0) {
        Write-Log "[Proxy] No proxy-enabled clients found in '$DomainName'" -Verbose
        return $true
    }

    Write-Log "[Proxy] Unconfiguring proxy on $($clients.Count) client(s) in '$DomainName'" -Activity

    $ok = $true
    foreach ($vm in $clients) {
        # In-guest unconfiguration (requires running VM + PSDirect)
        $vmObj = Get-VM2 -Name $vm.vmName -ErrorAction SilentlyContinue
        if ($vmObj -and $vmObj.State -eq 'Running') {
            $r = Remove-WindowsClientProxy -VmName $vm.vmName -Domain $DomainName
            if (-not $r) { $ok = $false }
        }
        else {
            Write-Log "[Proxy] $($vm.vmName): VM not running; skipping in-guest proxy removal (ACLs + vmNote still updated)" -Warning
        }

        # Host-side: clear Hyper-V port ACLs (always possible, VM state irrelevant)
        Clear-VmProxyEnforcement -VmName $vm.vmName

        # Update VM Note so useProxy reflects reality
        Update-VMNoteProperty -VmName $vm.vmName -PropertyName 'useProxy' -PropertyValue $false
        Write-Log "[Proxy] $($vm.vmName): useProxy set to false in VM Note"
    }

    return $ok
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
        [Parameter(Mandatory)] [string]$PublicKeyContent,
        [Parameter(Mandatory)] [string]$ProxyIP
    )

    $scriptBlock = {
        param($privKey, $pubKey, $proxyFqdn, $proxyIP)
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

            # ACL story on the SOURCE key (C:\ProgramData\memlabs\ssh):
            #   - Owner = BUILTIN\Administrators, FullControl for SYSTEM + Admins.
            #   - Authenticated Users get READ. Lab-only tradeoff: any logged-in
            #     domain user can read the private key, but it's the same key
            #     that's already authorized for vmbuildadmin on every Linux VM
            #     in the lab, so the exposure is bounded.
            #
            # Why allow Authenticated Users read: shortcuts on Public Desktop
            # are launched by domain admins whose UAC-filtered token does NOT
            # carry the Administrators SID. With an Admins-only ACL, ssh.exe
            # under that token can't open() the key and falls back to a
            # password prompt ('Load key ...: Permission denied').
            #
            # The wrapper (memlabs-ssh-proxy.cmd, installed below) copies the
            # key into the caller's %LOCALAPPDATA% with a user-private ACL,
            # then runs ssh -i on that copy. OpenSSH's strict-permissions
            # check then sees a file owned by the current user with no other
            # principals, which it accepts.
            #
            # NOTE: starting from `New-Object FileSecurity` (empty descriptor)
            # leaves owner unset, which OpenSSH treats as untrusted and
            # rejects the key. Always start from Get-Acl and mutate.
            $acl = Get-Acl -Path $privPath
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }
            $sysSid  = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'         # NT AUTHORITY\SYSTEM
            $admSid  = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'     # BUILTIN\Administrators
            $authSid = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-11'         # NT AUTHORITY\Authenticated Users
            $acl.SetOwner($admSid)
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $sysSid, 'FullControl', 'Allow')))
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $admSid, 'FullControl', 'Allow')))
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $authSid, 'Read', 'Allow')))
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

            # Install a wrapper that stages a user-private copy of the key
            # under %LOCALAPPDATA%\memlabs\ssh on first use. OpenSSH on
            # Windows requires the key file to be readable ONLY by the caller
            # (or SYSTEM/Admins) AND owned by one of those -- the source key
            # in ProgramData allows Authenticated Users read, which OpenSSH
            # rejects with 'bad permissions'. Per-user copy sidesteps both
            # the strict check and the UAC token-filtering issue (non-elevated
            # admins don't carry the Admins SID and can't read an Admins-only
            # ACL even though they're nominally admins).
            $wrapperPath = Join-Path $sshDir 'memlabs-ssh-proxy.cmd'
            $wrapper = @"
@echo off
setlocal
set SRC=$privPath
set DST=%LOCALAPPDATA%\memlabs\ssh\memlabs_ed25519
if not exist "%LOCALAPPDATA%\memlabs\ssh" mkdir "%LOCALAPPDATA%\memlabs\ssh" >nul 2>&1
if not exist "%DST%" (
    copy /Y "%SRC%" "%DST%" >nul
    icacls "%DST%" /inheritance:r >nul 2>&1
    icacls "%DST%" /grant:r "%USERNAME%:F" >nul 2>&1
    icacls "%DST%" /grant:r "SYSTEM:F" >nul 2>&1
)
"$sshExe" -i "%DST%" -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL vmbuildadmin@$proxyIP %*
endlocal
"@
            [System.IO.File]::WriteAllText($wrapperPath, $wrapper)

            # Interactive SSH shell. cmd.exe /k keeps the window open after
            # ssh exits so the user can see any messages.
            $lnk1 = Join-Path $desktop "SSH to $proxyFqdn.lnk"
            $sc1 = $shell.CreateShortcut($lnk1)
            $sc1.TargetPath = 'C:\Windows\System32\cmd.exe'
            $sc1.Arguments = "/k `"$wrapperPath`""
            $sc1.WorkingDirectory = 'C:\'
            $sc1.IconLocation = "$sshExe,0"
            $sc1.Description = "SSH to $proxyFqdn ($proxyIP) as vmbuildadmin"
            $sc1.Save()

            # Squid access-log tail (pass tail command as wrapper args)
            $lnk2 = Join-Path $desktop 'Squid Access Log.lnk'
            $sc2 = $shell.CreateShortcut($lnk2)
            $sc2.TargetPath = 'C:\Windows\System32\cmd.exe'
            $sc2.Arguments = "/k `"$wrapperPath`" sudo tail -n 100 -F /var/log/squid/access.log"
            $sc2.WorkingDirectory = 'C:\'
            $sc2.IconLocation = "$sshExe,0"
            $sc2.Description = "Tail /var/log/squid/access.log on $proxyFqdn ($proxyIP)"
            $sc2.Save()

            # Proxy Admin web UI (opens default browser)
            $lnk3 = Join-Path $desktop "Proxy Admin - $proxyFqdn.lnk"
            $sc3 = $shell.CreateShortcut($lnk3)
            $sc3.TargetPath = "http://${proxyIP}:8443"
            $sc3.Description = "Open Proxy Admin blocklist manager on $proxyFqdn ($proxyIP)"
            $sc3.Save()

            return @{ Ok = $true; SshDir = $sshDir; Shortcuts = @($lnk1, $lnk2, $lnk3) }
        }
        catch {
            return @{ Ok = $false; Error = $_.ToString() }
        }
    }

    $result = Invoke-VmCommand -VmName $VmName -VmDomainName $Domain `
        -ScriptBlock $scriptBlock -ArgumentList $PrivateKeyContent, $PublicKeyContent, $ProxyFqdn, $ProxyIP `
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
    Write-Log "[Proxy] $VmName`: Installed SSH key + Public Desktop shortcuts (-> $ProxyIP)"
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
    $proxyIP = Get-LinuxVmExpectedStaticIP -VmObject $proxyVm -DeployConfig $deployConfig
    if (-not $proxyIP) {
        Write-Log "[Proxy] Could not determine Proxy IP from network; skipping SSH shortcuts" -Warning
        return $false
    }

    $ok = $true
    foreach ($vm in $targets) {
        Write-Log "[Proxy] Installing SSH key + shortcuts on $($vm.vmName) -> $proxyIP ($proxyFqdn)"
        $r = Set-ProxyAdminAccessOnVm -VmName $vm.vmName -Domain $deployConfig.vmOptions.domainName `
                -ProxyFqdn $proxyFqdn -PrivateKeyContent $privContent -PublicKeyContent $pubContent `
                -ProxyIP $proxyIP
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
            # current user should have access, AND the file must have an
            # owner OpenSSH recognises (current user, Administrators, SYSTEM).
            # Starting from `New-Object FileSecurity` leaves owner unset and
            # ssh.exe rejects the key with 'bad permissions'. Mutate the
            # existing ACL instead.
            try {
                $acl = Get-Acl -Path $userKey
                $acl.SetAccessRuleProtection($true, $false)
                foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }
                $me = "$env:USERDOMAIN\$env:USERNAME"
                $meAccount = New-Object System.Security.Principal.NTAccount $me
                $acl.SetOwner($meAccount)
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
        $proxyIP = Get-LinuxVmExpectedStaticIP -VmObject $proxyVm -DeployConfig $deployConfig
        if (-not $proxyIP) {
            Write-Log "[Proxy] Could not determine Proxy IP from network; skipping host shortcuts" -Warning
            return $false
        }

        $desktop = [Environment]::GetFolderPath('Desktop')
        if (-not $desktop -or -not (Test-Path $desktop)) {
            Write-Log "[Proxy] Could not resolve host Desktop folder; skipping shortcuts" -Warning
            return $false
        }

        $shell = New-Object -ComObject WScript.Shell
        $sshArgsBase = "-i `"$($key.PrivateKeyPath)`" -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL vmbuildadmin@$proxyIP"

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
        $sc1.Description = "SSH to $proxyFqdn ($proxyIP) as vmbuildadmin"
        $sc1.Save()

        # Qualify with FQDN on the host so multiple labs/domains don't collide.
        $lnk2 = Join-Path $desktop "Squid Access Log - $proxyFqdn.lnk"
        $sc2 = $shell.CreateShortcut($lnk2)
        $sc2.TargetPath = 'C:\Windows\System32\cmd.exe'
        $sc2.Arguments = "/k `"`"$sshExe`" $sshArgsBase sudo tail -n 100 -F /var/log/squid/access.log`""
        $sc2.WorkingDirectory = 'C:\'
        $sc2.IconLocation = "$sshExe,0"
        $sc2.Description = "Tail /var/log/squid/access.log on $proxyFqdn ($proxyIP)"
        $sc2.Save()

        Write-Log "[Proxy] Host desktop shortcuts created for $proxyFqdn ($proxyIP)"
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

function Remove-ProxyAdminAccessForDomain {
    <#
    .SYNOPSIS
        Remove SSH shortcuts from guest Windows VMs in the domain when a
        Proxy VM is removed.
    .DESCRIPTION
        Enumerates running admin-role VMs (DC, CAS, Primary, etc.) and
        deletes the Public Desktop SSH/Squid shortcuts via PSDirect.
        Best-effort: VMs that are off or unreachable are skipped.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string]$DomainName,
        [Parameter(Mandatory)] [string]$ProxyFqdn
    )

    $adminRoles = @('DC', 'BDC', 'CAS', 'Primary', 'Secondary', 'SiteSystem', 'PassiveSite')
    $allVms = @(Get-List -Type VM -DomainName $DomainName -SmartUpdate)
    $targets = @($allVms | Where-Object {
        $_.role -in $adminRoles -and -not (Test-VmIsLinux -Vm $_)
    })
    if (-not $targets) { return }

    $scriptBlock = {
        param($proxyFqdn)
        $desktop = 'C:\Users\Public\Desktop'
        $removed = 0
        foreach ($name in @("SSH to $proxyFqdn.lnk", 'Squid Access Log.lnk')) {
            $path = Join-Path $desktop $name
            if (Test-Path $path) {
                Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
                $removed++
            }
        }
        return $removed
    }

    foreach ($vm in $targets) {
        $vmObj = Get-VM2 -Name $vm.vmName -ErrorAction SilentlyContinue
        if (-not $vmObj -or $vmObj.State -ne 'Running') { continue }

        try {
            $result = Invoke-VmCommand -VmName $vm.vmName -VmDomainName $DomainName `
                -ScriptBlock $scriptBlock -ArgumentList $ProxyFqdn `
                -DisplayName "Remove proxy SSH shortcuts"
            if (-not $result.ScriptBlockFailed -and $result.ScriptBlockOutput -gt 0) {
                Write-Log "[Proxy] $($vm.vmName): Removed $($result.ScriptBlockOutput) SSH shortcut(s)" -SubActivity
            }
        }
        catch {
            Write-Log "[Proxy] $($vm.vmName): Failed to remove SSH shortcuts: $_" -Warning
        }
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

    # Clean up any stale bake VMs from a previous interrupted run.
    # Ctrl+C can bypass the inner finally block, leaving an orphan VM that
    # holds the VHDX file lock and blocks the next attempt.
    $staleVMs = @(Get-VM -Name 'memlabs-bake-*' -ErrorAction SilentlyContinue)
    foreach ($staleVM in $staleVMs) {
        Write-Log "Bake: removing stale bake VM '$($staleVM.Name)' (state=$($staleVM.State))." -Warning
        if ($staleVM.State -ne 'Off') {
            Stop-VM -VM $staleVM -TurnOff -Force -ErrorAction SilentlyContinue
        }
        Remove-VM -VM $staleVM -Force -ErrorAction SilentlyContinue
    }

    # Auto-manage only the canonical 'MemLabsNAT' / 'Default Switch' names; for
    # anything exotic, require the caller to have it set up already.
    if ($SwitchName -in @('MemLabsNAT', 'Default Switch')) {
        $SwitchName = 'MemLabsNAT'

        # Migration: earlier bake code created a NAT named 'MemLabsNATNat'
        # with prefix 172.16.200.0/24.  Test-NetworkNat (called by
        # Add-SwitchAndDhcp) names NATs by subnet ('172.16.200.0') and will
        # fail to create a duplicate-prefix NAT.  Remove the legacy name so
        # the standard pipeline succeeds.
        $legacyNat = Get-NetNat -Name 'MemLabsNATNat' -ErrorAction SilentlyContinue
        if ($legacyNat) {
            Write-Log "Bake: removing legacy NAT 'MemLabsNATNat' (replaced by '172.16.200.0')." -Warning
            Remove-NetNat -Name 'MemLabsNATNat' -Confirm:$false -ErrorAction SilentlyContinue
        }

        # Reuse the same Add-SwitchAndDhcp / Test-NetworkSwitch / Test-DHCPScope
        # pipeline that New-Lab uses for domain networks. This creates the
        # internal switch, sets host IP to .200, adds the NetNat, installs
        # DHCP if needed, and creates a scope (.20-.199, gateway .200, DNS
        # 8.8.8.8).  The bake VM will get an address via DHCP; the static
        # network-config in the seed ISO is a belt-and-suspenders fallback.
        $switchOk = Add-SwitchAndDhcp -NetworkName $SwitchName -NetworkSubnet '172.16.200.0' -DNSServer '8.8.8.8'
        if (-not $switchOk) {
            throw "Bake: failed to create/verify switch + DHCP for '$SwitchName' (172.16.200.0/24)."
        }
        $isMemLabsNAT = $true
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

    # Static network config for the MemLabsNAT switch (172.16.200.0/24).
    # Belt-and-suspenders with the DHCP scope created by Add-SwitchAndDhcp
    # above -- if cloud-init reads this file the static config wins; if not,
    # DHCP provides the address.  Gateway is .200 (the host vNIC IP set by
    # Test-NetworkSwitch, matching every other memlabs network).
    # cloud-init reads 'network-config' from the NoCloud seed alongside
    # meta-data and user-data.
    $networkConfig = @"
version: 2
renderer: networkd
ethernets:
  primary:
    match:
      name: "e*"
    addresses: [172.16.200.10/24]
    routes:
      - to: 0.0.0.0/0
        via: 172.16.200.200
    nameservers:
      addresses: [8.8.8.8, 1.1.1.1]
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
    # apt traffic.
    #
    # Networking notes:
    #   Previous bake forced cloud-init's netplan renderer to NetworkManager
    #   and disabled systemd-networkd. That looked clean but it removed the
    #   only DHCP mechanism that actually works on first boot:
    #     - Ubuntu 24.04 dropped isc-dhcp-client entirely (no dhclient
    #       fallback for anyone).
    #     - NetworkManager doesn't auto-claim eth0 in the first ~60s after a
    #       cloud-init reseed, so the deploy's Wait-ForLinuxVm loop times
    #       out with no IPv4.
    #   Fix: leave netplan on its default systemd-networkd renderer (same as
    #   the Server variant, which is proven working), keep NM installed +
    #   enabled for the GUI session, but tell NM to leave eth* unmanaged so
    #   the two don't race for the lease. NM still owns wifi / dynamic GUI
    #   connections; networkd owns the static lab interface.
    $desktopPackagesYaml = ''
    $desktopRuncmdYaml = ''
    # Always bake the hv-kvp-daemon.service override so the deployed VHDX
    # boots with our race-free unit on disk from the start.  Without this
    # the upstream unit (BindsTo= + ConditionPathExists= on /dev/vmbus/hv_kvp)
    # runs before cloud-init's write_files writes the override, fails due
    # to the ~40s device-registration race, and systemd marks the unit
    # dependency-failed for the rest of the boot.  KVP stays dark and the
    # host can't read the guest IP.
    #
    # The deploy seed ISO writes the same file via its own write_files
    # (idempotent overwrite); having it baked in just ensures the very
    # first systemd pass uses the override.
    $bakeWriteFilesYaml = @'

write_files:
  - path: /etc/systemd/system/hv-kvp-daemon.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Hyper-V KVP Protocol Daemon (memlabs override)
      ConditionVirtualization=microsoft
      ConditionKernelCommandLine=!snapd_recovery_mode
      DefaultDependencies=no
      After=systemd-remount-fs.service systemd-modules-load.service
      Before=shutdown.target cloud-init-local.service walinuxagent.service
      Conflicts=shutdown.target
      RequiresMountsFor=/var/lib/hyperv
      [Service]
      TimeoutStartSec=75
      ExecStartPre=/bin/bash -c 'for i in $(seq 1 60); do [ -e /dev/vmbus/hv_kvp ] && exit 0; sleep 1; done; exit 1'
      ExecStart=/usr/sbin/hv_kvp_daemon -n
      Restart=on-failure
      RestartSec=5
      [Install]
      WantedBy=multi-user.target
'@

    if ($Variant -eq 'Desktop') {
        $desktopPackagesYaml = @'
  - ubuntu-desktop-minimal
  - gdm3
  - network-manager
  - xrdp
  - xorgxrdp
'@

        # NetworkManager keyfile config: keep NM running for the GUI, but
        # ignore the lab interface so systemd-networkd's DHCP wins
        # unambiguously on every boot.
        # NOTE: "`n" is required because PowerShell here-strings do NOT
        # include a trailing newline. Without it, the last line of the
        # previous write_files entry (WantedBy=multi-user.target) runs
        # into this entry's '- path:' on the same line, producing a
        # duplicate 'content:' key that makes cloud-init write NM keyfile
        # config into the KVP service path.
        $bakeWriteFilesYaml += "`n"
        $bakeWriteFilesYaml += @'
  - path: /etc/NetworkManager/conf.d/10-memlabs-unmanage-eth.conf
    content: |
      [keyfile]
      unmanaged-devices=interface-name:eth*
'@

        $desktopRuncmdYaml = @'
  - systemctl set-default graphical.target
  - systemctl enable gdm3.service || true
  - systemctl enable NetworkManager.service || true
  - systemctl enable xrdp.service || true
  - adduser xrdp ssl-cert || true
  - ufw allow 3389/tcp || true
  - "dpkg -l ubuntu-desktop-minimal xrdp xorgxrdp | grep -c '^ii' | grep -q '^3$' || { echo 'BAKE FAILED: desktop packages not installed'; shutdown -c; poweroff; }"
'@
    }

    # Temporary console user for bake debugging (vmconnect).  Password comes
    # from $Common.LocalAdmin so nothing is hardcoded in the repo.  The user
    # is deleted from /etc/shadow before cloud-init clean so the baked VHDX
    # ships with no stale credentials.
    $bakeUserYaml = ''
    $bakeUserCleanupYaml = ''
    if ($Common -and $Common.LocalAdmin) {
        try { $bakePwd = $Common.LocalAdmin.GetNetworkCredential().Password } catch { $bakePwd = $null }
        if ($bakePwd) {
            $bakePwdQuoted = "'" + ($bakePwd -replace "'", "''") + "'"
            $bakeUserYaml = @"

users:
  - name: memlabs
    plain_text_passwd: $bakePwdQuoted
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash

ssh_pwauth: true
"@
            $bakeUserCleanupYaml = '  - userdel -r memlabs 2>/dev/null || true'
        }
    }

    $userData = @"
#cloud-config
hostname: memlabs-bake
preserve_hostname: false
$bakeUserYaml

package_update: true
package_upgrade: false
packages:
  - linux-tools-virtual
  - linux-cloud-tools-virtual
  - qemu-guest-agent
  - openssh-server
$desktopPackagesYaml
$bakeWriteFilesYaml
runcmd:
  - systemctl daemon-reload || true
  - systemctl enable qemu-guest-agent.service || true
  - systemctl enable hv-kvp-daemon.service || true
  - systemctl enable hv-vss-daemon.service || true
  - dpkg -s "linux-cloud-tools-`$(uname -r)" >/dev/null 2>&1 || apt-get install -y "linux-tools-`$(uname -r)" "linux-cloud-tools-`$(uname -r)" || true
$desktopRuncmdYaml
$bakeUserCleanupYaml
  - systemctl stop unattended-upgrades.service 2>/dev/null || true
  - systemctl disable unattended-upgrades.service 2>/dev/null || true
  - cloud-init clean --logs --seed --machine-id || true
  - truncate -s 0 /etc/machine-id
  - rm -f /var/lib/dbus/machine-id
  - rm -f /etc/netplan/50-cloud-init.yaml
  - shutdown -h now
"@

    [System.IO.File]::WriteAllText((Join-Path $stageDir 'meta-data'), ($metaData -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $stageDir 'user-data'), ($userData -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
    # Static network-config only applies to the MemLabsNAT switch (known
    # 172.16.200.0/24 topology).  Custom switches have their own DHCP/routing
    # and the hardcoded .10 address would be wrong.
    if ($isMemLabsNAT) {
        [System.IO.File]::WriteAllText((Join-Path $stageDir 'network-config'), ($networkConfig -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
    }

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
        Write-Log "Bake: VM started; monitoring NIC traffic to verify network connectivity..."

        # Enable Hyper-V resource metering so we can read NIC byte counters.
        # Without metering, Get-VMNetworkAdapter.BytesReceived is always 0.
        Enable-VMResourceMetering -VM $vm -ErrorAction SilentlyContinue

        # NIC traffic check.  We can't rely on KVP for an IP (the daemon is
        # being installed during this bake), but we CAN verify the NIC is
        # sending/receiving traffic.  If the interface name doesn't match the
        # network-config (e.g. eth0 vs enp1s0), netplan silently ignores the
        # config and the NIC stays completely dark -- zero bytes in/out.
        # Catch that within 90s instead of waiting the full bake timeout.
        $nicWaitSec = 90
        $nicElapsed = 0
        $nicOk = $false
        while ($nicElapsed -lt $nicWaitSec) {
            Start-Sleep -Seconds 10
            $nicElapsed += 10
            $nic = Get-VMNetworkAdapter -VMName $vmName -ErrorAction SilentlyContinue
            $rxBytes = 0; $txBytes = 0
            if ($nic) {
                # Measure-VM aggregates metered traffic; fall back to NIC
                # counters if metering data isn't available yet.
                try {
                    $report = (Measure-VM -VM $vm -ErrorAction SilentlyContinue).NetworkMeteredTrafficReport
                    if ($report) {
                        $rxBytes = ($report | Where-Object { $_.Direction -eq 'Inbound' } |
                            Measure-Object -Property TotalTraffic -Sum).Sum
                        $txBytes = ($report | Where-Object { $_.Direction -eq 'Outbound' } |
                            Measure-Object -Property TotalTraffic -Sum).Sum
                    }
                }
                catch { }
            }
            if ($rxBytes -gt 0 -or $txBytes -gt 0) {
                Write-Log "Bake: NIC has traffic after ${nicElapsed}s (rx=${rxBytes}MB tx=${txBytes}MB). Network is up." -Success
                $nicOk = $true
                break
            }
        }
        if (-not $nicOk) {
            Write-Log "Bake: VM '$vmName' has zero NIC traffic after ${nicWaitSec}s. Network config likely failed (interface name mismatch?). Aborting." -Failure
            Stop-VM -Name $vmName -TurnOff -Force -ErrorAction SilentlyContinue
            throw "Bake: VM '$vmName' has zero NIC traffic after ${nicWaitSec}s. The guest interface name may not match the network-config. Check 'ip link' in the guest console."
        }

        Write-Log "Bake: waiting up to $TimeoutMinutes min for cloud-init + shutdown..."

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
        # Stop the VM before removing it.  Remove-VM -Force should handle
        # running VMs, but an explicit TurnOff is more reliable at releasing
        # the VHDX file handle so the caller can move/delete it immediately.
        $bakeVM = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if ($bakeVM) {
            if ($bakeVM.State -ne 'Off') {
                Stop-VM -VM $bakeVM -TurnOff -Force -ErrorAction SilentlyContinue
            }
            Disable-VMResourceMetering -VM $bakeVM -ErrorAction SilentlyContinue
            # Remove-VM keeps the VHDX file; we only want to drop the VM
            # config and DVD attachment.
            Remove-VM -VM $bakeVM -Force -ErrorAction SilentlyContinue
        }
        Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Bake complete on $VhdxPath" -Success
    return $true
}




