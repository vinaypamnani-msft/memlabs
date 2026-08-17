# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
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

# ── Script directory for external .sh / .py files ────────────────────────
# All non-trivial bash scripts live as standalone files under
# vmbuild/scripts/linux/.  Get-LinuxScript reads them, optionally prepends
# variable assignments, and returns the content ready for
# Invoke-LinuxVmCommand -BashCommand.
$script:LinuxScriptDir = Join-Path (Split-Path $PSScriptRoot) 'scripts\linux'

function Get-LinuxScript {
    <#
    .SYNOPSIS
        Read an external bash script from scripts/linux/ and optionally
        inject PowerShell variables as bash variable assignments.

    .PARAMETER Name
        Relative path under scripts/linux/ without the .sh extension.
        E.g. "proxy/install-squid", "bake/01-system-updates",
        "roles/realm-join".

    .PARAMETER Variables
        Hashtable of VARNAME = value pairs. Each is emitted as a
        single-quoted bash assignment prepended to the script body:
            VARNAME='value'
        Values containing single quotes are escaped ('\'').

    .PARAMETER IncludeAptRetry
        When set, sources lib/apt-retry.sh at the top of the script
        so the apt_retry function is available.

    .PARAMETER IncludeSetDcDns
        When set, sources lib/set-dc-dns.sh at the top of the script so the
        memlabs_set_dc_dns <dc-ip> <domain> function is available (the single
        source of truth for the DC-DNS config, shared with Set-LinuxVmsDcDns).

    .OUTPUTS
        [string] — the complete bash script body.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Variables,
        [switch]$IncludeAptRetry,
        [switch]$IncludeSetDcDns
    )

    $scriptPath = Join-Path $script:LinuxScriptDir "$Name.sh"
    if (-not (Test-Path $scriptPath)) {
        throw "Get-LinuxScript: script not found: $scriptPath"
    }
    $body = Get-Content -Path $scriptPath -Raw

    # Prepend variable assignments (single-quoted to avoid bash expansion).
    $prefix = ''
    if ($Variables -and $Variables.Count -gt 0) {
        $lines = foreach ($key in $Variables.Keys) {
            $val = $Variables[$key] -replace "'", "'\\''"
            "${key}='${val}'"
        }
        $prefix = ($lines -join "`n") + "`n"
    }

    # Optionally prepend the shared apt_retry helper.
    if ($IncludeAptRetry.IsPresent) {
        $aptRetryPath = Join-Path $script:LinuxScriptDir 'lib\apt-retry.sh'
        if (Test-Path $aptRetryPath) {
            $aptRetryBody = Get-Content -Path $aptRetryPath -Raw
            # Strip the shebang from the helper since we're inlining it.
            $aptRetryBody = $aptRetryBody -replace '^#!/bin/bash\r?\n', ''
            $prefix = $aptRetryBody + "`n" + $prefix
        }
    }

    # Optionally prepend the shared memlabs_set_dc_dns helper (single source of
    # truth for the DC-DNS config, shared with Set-LinuxVmsDcDns).
    if ($IncludeSetDcDns.IsPresent) {
        $setDcDnsPath = Join-Path $script:LinuxScriptDir 'lib\set-dc-dns.sh'
        if (Test-Path $setDcDnsPath) {
            $setDcDnsBody = Get-Content -Path $setDcDnsPath -Raw
            # Strip the shebang from the helper since we're inlining it.
            $setDcDnsBody = $setDcDnsBody -replace '^#!/bin/bash\r?\n', ''
            $prefix = $setDcDnsBody + "`n" + $prefix
        }
    }

    if ($prefix) {
        # Insert prefix after the shebang line (if present) so bash sees
        # the variables before the script body uses them.
        if ($body -match '^(#!/[^\r\n]+\r?\n)') {
            $shebang = $Matches[1]
            $rest = $body.Substring($shebang.Length)
            $body = $shebang + $prefix + $rest
        }
        else {
            $body = $prefix + $body
        }
    }

    return $body
}

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

    # IMAPI2FS COM object is not thread-safe; parallel Linux VM creation
    # (runspaces) can collide on New-Object, producing 0xC0AAB138. Use a
    # named mutex so only one thread builds an ISO at a time.
    $mutex = [System.Threading.Mutex]::new($false, 'Global\MemlabsImapi2fsLock')
    try {
        $null = $mutex.WaitOne()
        $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
        try {
            $fsi.FileSystemsToCreate = 3   # ISO9660 (1) | Joliet (2)
            $fsi.VolumeName = $VolumeLabel

            # IMAPI defaults the result-image size cap to a small (CD-sized) media
            # profile, so AddTree throws "result image ... larger than the current
            # configured limit" once the payload exceeds ~650MB (e.g. the download-
            # cache ISO that now carries SSMS). Raise FreeMediaBlocks (2048-byte
            # blocks) to cover the actual source size with margin so arbitrarily
            # large ISOs build. Harmless for the tiny cloud-init seed (a few KB).
            try {
                $srcBytes = (Get-ChildItem -LiteralPath $SourceDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                if (-not $srcBytes) { $srcBytes = 0 }
                $needBlocks = [math]::Ceiling((([double]$srcBytes * 1.2) + (64 * 1MB)) / 2048)
                if ($needBlocks -gt [double]$fsi.FreeMediaBlocks) { $fsi.FreeMediaBlocks = [int]$needBlocks }
            }
            catch { }

            $fsi.Root.AddTree($SourceDir, $false)
            $result = $fsi.CreateResultImage()
            [MemlabsIsoFile]::Create($OutputIsoPath, $result.ImageStream, $result.BlockSize, $result.TotalBlocks)
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($fsi) | Out-Null
        }
    }
    finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
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
          - vmbuildadmin user (deployment/automation account) with sudo NOPASSWD
            and the memlabs host ed25519 public key authorized for SSH
          - optional -LocalAdminUser account (workgroup human logon, e.g. 'admin')
            with sudo NOPASSWD + the lab password; omitted for domain-joined VMs
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
        [int]$Prefix = 24,

        # Workgroup (non-domain-joined) Linux VMs get a second LOCAL account named
        # after vmOptions.adminName (default 'admin'), mirroring the Windows
        # workgroup model (Phase2WorkgroupMember creates both vmbuildadmin and the
        # adminName local account). This is the human logon for a standalone box;
        # vmbuildadmin stays the deployment/automation account. Domain-joined VMs
        # omit this (adminName is a domain account there, and a local one would
        # shadow it via NSS files-before-sss).
        [Parameter(Mandatory = $false)]
        [string]$LocalAdminUser
    )

    # oscdimg is preferred when available (faster, more deterministic), but
    # we fall back to IMAPI2FS so the build doesn't require the Windows ADK.
    $oscdimg = Get-OscdimgPath

    $sshKey = Get-LinuxAdminSshKeyPair
    $instanceId = "memlabs-$VmName-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
    $fqdn = "$VmName.$Domain".ToLower()

    # Normalize the optional workgroup local-admin account name. Ignore it if it
    # collides with the deployment account (vmbuildadmin) so we never emit a
    # duplicate users: entry.
    $localAdminUser = $null
    if ($LocalAdminUser -and $LocalAdminUser.Trim() -and $LocalAdminUser.Trim().ToLower() -ne 'vmbuildadmin') {
        $localAdminUser = $LocalAdminUser.Trim()
    }

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
        # Optional third chpasswd entry for the workgroup local-admin account.
        $localAdminChpasswd = ''
        if ($localAdminUser) {
            $localAdminChpasswd = @"

    - name: $localAdminUser
      password: $pwQuoted
      type: text
"@
        }
        $chpasswdBlock = @"

chpasswd:
  expire: false
  users:
    - name: vmbuildadmin
      password: $pwQuoted
      type: text
    - name: root
      password: $pwQuoted
      type: text$localAdminChpasswd
"@
    }
    else {
        $lockPasswdYaml = 'true'
        $chpasswdBlock = ''
    }

    # Optional second LOCAL account for workgroup Linux VMs: the human logon
    # (adminName, e.g. 'admin'), sudo NOPASSWD, same lab password + host key as
    # vmbuildadmin. vmbuildadmin stays the deployment account. Empty for
    # domain-joined VMs (adminName is a domain account there).
    $localAdminUserYaml = ''
    if ($localAdminUser) {
        $localAdminUserYaml = @"

  - name: $localAdminUser
    gecos: memlabs local admin
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    lock_passwd: $lockPasswdYaml
    ssh_authorized_keys:
      - $($sshKey.PublicKey)
"@
    }

    # linux-tools-virtual / linux-cloud-tools-virtual provide hv_kvp_daemon and
    # hv_vss_daemon. Without them Get-VMNetworkAdapter.IPAddresses stays empty
    # on the host even after the guest has a working DHCP lease, and we have no
    # way to discover the VM's IP.
    #
    # NOTE: samba is intentionally NOT in this list. It is installed by a
    # detect-and-install runcmd below instead of the cloud-init 'packages:'
    # module. The packages module has no retry, so a first-boot apt hiccup on a
    # contended host (worst on the Proxy) silently left smbd absent and TCP 445
    # down. See the samba runcmd block for the idempotent install.
    $packages = @(
        'openssh-server',
        'qemu-guest-agent',
        'linux-tools-virtual',
        'linux-cloud-tools-virtual'
    ) + $ExtraPackages | Select-Object -Unique

    # These go through roles/ensure-packages.sh as the FIRST runcmd rather than
    # cloud-init's 'packages:' module. The module always runs apt-get update +
    # an install transaction, so a fully-baked image still paid a network round
    # trip and a large dpkg write on every first boot -- the single biggest
    # chunk of Linux first boot, landing while Phase 1 copies every other VM's
    # base image. The script skips apt entirely when nothing is missing, so the
    # baked set (bake/02-base-packages.sh) costs a few `dpkg -s` calls.
    # It must be the first runcmd: the items below enable services it installs.
    $ensurePackagesScript = Get-LinuxScript -Name 'roles/ensure-packages' -IncludeAptRetry -Variables @{
        MEMLABS_PACKAGES = ($packages -join ' ')
    }
    $ensurePackagesLf = $ensurePackagesScript -replace "`r`n", "`n"
    $ensurePackagesB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ensurePackagesLf))

    # Build the shared Samba-ensure script (with the apt-retry/dpkg-recovery
    # helpers inlined) and base64-encode it for a single runcmd line. The same
    # script runs at Phase 11 (Test-LinuxSmbAccess self-heal), so first boot and
    # self-heal share identical detect-skip + dpkg-recovery + install logic.
    $ensureSambaScript = Get-LinuxScript -Name 'roles/ensure-samba' -IncludeAptRetry
    $ensureSambaLf = $ensureSambaScript -replace "`r`n", "`n"
    $ensureSambaB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ensureSambaLf))

    $runcmd = @(
        # DNS first: systemd-resolved consults FallbackDNS only when no
        # DHCP/static DNS answers, so the write_files dropin has to be live
        # before anything tries to resolve archive.ubuntu.com. It used to sit
        # below the package step, which left the very first apt of the boot
        # resolving against whatever was there.
        'systemctl restart systemd-resolved || true',
        # Then packages: installs anything the baked image is missing, and is a
        # no-op (no apt at all) once bake/02-base-packages.sh ships them. Must
        # stay ahead of the service-enable lines below, which need them.
        "bash -c 'echo $ensurePackagesB64 | base64 -d > /root/memlabs-ensure-packages.sh && chmod 0700 /root/memlabs-ensure-packages.sh && /root/memlabs-ensure-packages.sh; rm -f /root/memlabs-ensure-packages.sh' || true",
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
        # Prevent maintenance-mode boot: add fsck.mode=force fsck.repair=yes
        # to the kernel command line so filesystem inconsistencies are auto-
        # repaired instead of prompting. The emergency.service override and
        # no-emergency.conf from write_files above are already picked up by
        # the daemon-reload earlier in this runcmd list.
        'grep -q ''fsck.repair=yes'' /etc/default/grub || { sed -i ''/^GRUB_CMDLINE_LINUX_DEFAULT=/s/"$/ fsck.mode=force fsck.repair=yes"/'' /etc/default/grub && update-grub; } || true',
        # Delete the temporary bake-time console user. The bake runcmd
        # already runs userdel, but if it failed silently (|| true) the
        # account ships in the VHDX and every deployed VM inherits it.
        'userdel -r memlabs 2>/dev/null || true',
        # Install sshd watchdog cron job: every 5 minutes, check tcp/22
        # and restart sshd if it's not listening.
        '(crontab -l 2>/dev/null | grep -v memlabs-sshd-watchdog; echo "*/5 * * * * /usr/local/sbin/memlabs-sshd-watchdog") | crontab -',
        # Ensure Samba is installed + smbd enabled/listening, then set
        # vmbuildadmin's SMB password (same as console). The share gives file
        # access to /var/log and /home/vmbuildadmin when SSH is down.
        #
        # Runs the shared roles/ensure-samba.sh: detect-and-skip if samba is
        # already present (a future baked image), otherwise HEAL a corrupt
        # dpkg DB (recover_dpkg/repair_dpkg_status) and install with retries.
        # The plain cloud-init 'packages:' module (and a naive apt-get) abort
        # with "end of file after field name ''" when an ungraceful reboot has
        # truncated /var/lib/dpkg/status -- exactly the Proxy failure mode --
        # so the dpkg recovery must run before the install.
        "bash -c 'echo $ensureSambaB64 | base64 -d > /root/memlabs-ensure-samba.sh && chmod 0700 /root/memlabs-ensure-samba.sh && /root/memlabs-ensure-samba.sh; rm -f /root/memlabs-ensure-samba.sh' || true",
        # Allow SMB through the firewall.
        'ufw allow Samba || true'
    )

    # Set vmbuildadmin's Samba password if we have the console password.
    # printf pipes the password twice (new + confirm) to smbpasswd -a -s.
    if ($consolePassword) {
        $escapedPw = $consolePassword -replace "'", "'\''"
        $runcmd += "printf '$escapedPw\n$escapedPw\n' | smbpasswd -a -s vmbuildadmin"
        # Same for the workgroup local-admin account (human logon) when present.
        if ($localAdminUser) {
            $runcmd += "printf '$escapedPw\n$escapedPw\n' | smbpasswd -a -s $localAdminUser"
        }
    }

    $runcmd = $runcmd + $ExtraRunCmd
    # Flush all filesystem writes to disk as the final runcmd item, before
    # cloud-init's power_state reboot runs. The 'packages:' module above
    # writes the dpkg status DB; on ext4 with delayed allocation a reboot on a
    # heavily-loaded host can otherwise leave /var/lib/dpkg/status zero-length
    # ("dpkg: error: parsing file '/var/lib/dpkg/status' near line 0: end of
    # file"), which makes dpkg think nothing is installed and breaks every
    # later apt operation. An explicit sync closes that writeback window.
    $runcmd += 'sync'
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
      - $($sshKey.PublicKey)$localAdminUserYaml

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
  # Durability under unannounced hard power-off: these lab VMs can be hard
  # shut off without warning (nightly host maintenance ~02:00). Shrink the
  # dirty-page writeback window so a plug-pull loses at most ~1-2s of unflushed
  # data instead of the ~30s default -- the cheap, no-boot-risk resilience lever
  # (vs data=journal's write amplification). Applied on the post-cloud-init
  # reboot; also baked in via bake/03b for future images.
  - path: /etc/sysctl.d/90-memlabs-durability.conf
    permissions: '0644'
    content: |
      vm.dirty_writeback_centisecs = 100
      vm.dirty_expire_centisecs = 200
      vm.dirty_background_ratio = 5
      vm.dirty_ratio = 20
  # Helper: once the DC is online and serving DNS for the AD domain,
  # invoke this to route AD-domain resolution to the DC. Usage (run as root):
  #   memlabs-set-dns 192.168.6.1 [adatum.com]
  # It writes a netplan drop-in (60-memlabs-dc-dns.yaml, DC first on the link)
  # AND a systemd-resolved routing-domain drop-in that forces ALL queries for
  # the AD domain (incl. the _msdcs SRV zone) to the DC ONLY. The routing
  # domain is the authoritative fix: netplan MERGES nameserver lists so public
  # DNS ends up ahead of the DC, and the lab AD domain often collides with a
  # REAL internet domain (e.g. contoso.com) whose public resolvers happily
  # answer AD queries with wrong (Azure) IPs while the SRV lookups NXDOMAIN.
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
      # 1) netplan drop-in: DC first on the link (persists across reboot; DC
      #    forwards external names, public kept as belt-and-braces fallback).
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
      # 2) systemd-resolved routing domain: '~<domain>' tied to global DNS=<DC>
      #    is a MORE-SPECIFIC route than the per-link '.' default, so every AD
      #    query goes to the DC only while everything else still uses the link's
      #    (public) DNS. This wins regardless of netplan's list-merge ordering
      #    and regardless of whether the AD domain name exists on the internet.
      if [[ -n "`$SEARCH" ]]; then
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/memlabs-dc-route.conf <<EOF
      [Resolve]
      DNS=`$DC_DNS
      Domains=~`$SEARCH
      EOF
        chmod 644 /etc/systemd/resolved.conf.d/memlabs-dc-route.conf
      fi
      systemctl restart systemd-resolved || true
      echo "DNS now: `$(resolvectl dns 2>/dev/null | grep -v '^`$')"
      if [[ -n "`$SEARCH" ]]; then
        echo "AD route: `$(resolvectl domain 2>/dev/null | grep -i "`$SEARCH" || echo '(routing domain pending)')"
        echo "SRV test: `$(getent hosts "`$SEARCH" 2>/dev/null | head -1 || echo '(domain not resolving yet)')"
      fi
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
  # Prevent maintenance-mode boot: if the VM hits a filesystem
  # inconsistency or journal mismatch after a hard shutdown, systemd
  # drops to "Give root password for maintenance" -- sshd never starts
  # and the 20-hour deployment fails. Override emergency.service to
  # reboot instead of prompting.
  # Also written during bake (step 3b); having it here ensures deployed
  # VMs always have it regardless of base image age.
  - path: /etc/systemd/system.conf.d/no-emergency.conf
    permissions: '0644'
    content: |
      [Manager]
      DefaultTimeoutStartSec=180s
      DefaultTimeoutStopSec=90s
  - path: /etc/systemd/system/emergency.service.d/override.conf
    permissions: '0644'
    content: |
      [Service]
      ExecStart=
      ExecStart=-/usr/bin/systemctl reboot
  # sshd watchdog: every 5 minutes, verify sshd is listening on tcp/22.
  # If the port is closed, restart the service. Logs to syslog so
  # failures are visible in journalctl. This prevents the "long-uptime
  # sshd goes unresponsive" issue that causes 30-min probe timeouts.
  - path: /usr/local/sbin/memlabs-sshd-watchdog
    permissions: '0755'
    content: |
      #!/bin/bash
      if ! ss -tlnp | grep -q ':22\b'; then
        logger -t memlabs-sshd-watchdog "tcp/22 not listening, restarting sshd"
        systemctl restart ssh || systemctl restart sshd
      fi
  # Samba config: share /var/log (read-only) and /home/vmbuildadmin
  # so admins can browse logs and files via SMB when SSH is down.
  # Auth uses vmbuildadmin with the same password as LocalAdmin.
  - path: /etc/samba/smb.conf
    permissions: '0644'
    content: |
      [global]
        workgroup = WORKGROUP
        server string = %h (MemLabs)
        security = user
        map to guest = never
        log file = /var/log/samba/log.%m
        max log size = 1000
      [logs]
        path = /var/log
        browseable = yes
        read only = yes
        valid users = vmbuildadmin
      [home]
        path = /home/vmbuildadmin
        browseable = yes
        read only = no
        valid users = vmbuildadmin

# roles/ensure-packages.sh (first runcmd) owns package installation and runs
# apt-get update only when something is actually missing, so a baked image does
# no apt on first boot at all.
package_update: false
package_upgrade: false

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
        'sssd-ad',
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
    # Uses the same realm-join.sh file as Phase 3 — single source of truth.
    $joinVars = @{
        DOMAIN     = $domainLower
        DC_IP      = $dcIp
        ADMIN_USER = $adminUser
        ADMIN_PWD  = $pwBashSingle
    }
    # Optional per-VM domain user -> NOPASSWD sudo on the box (Windows parity).
    if ($ThisVm.PSObject.Properties.Name -contains 'domainUser' -and $ThisVm.domainUser) {
        $joinVars['DOMAIN_USER'] = $ThisVm.domainUser
    }
    $joinScript = Get-LinuxScript -Name 'roles/realm-join' -IncludeAptRetry -IncludeSetDcDns -Variables $joinVars

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
            Write-Log "$VmName`: Source VHDX $SourceDiskPath not found. It is downloaded from Azure storage via the file list -- ensure file download succeeded before deploying." -Failure
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
                    Write-Log "$VmName`: Could not remove stale VM dir $vmSubPath`: $($_.Exception.Message). Refusing to deploy on top of a stale OS disk." -Failure
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

        # Create DHCP reservation now that the MAC is available.
        # AssignedIP was stamped by Set-DeployConfigIPAddresses before Phase 1.
        # Skip if MAC is null (VM not yet started) — will retry after Start-VM2.
        # Skip if a reservation already exists for this MAC (rerun scenario).
        if ($DeployConfig) {
            $thisVmConfig = $DeployConfig.virtualMachines | Where-Object { $_.vmName -eq $VmName } | Select-Object -First 1
            if ($thisVmConfig -and $thisVmConfig.AssignedIP) {
                # DHCP/Hyper-V CIM calls run isolated (Get-VMMacIsolated /
                # *DHCPReservation* helpers) so their progress doesn't poison the bars.
                try {
                    $vmMac = Get-VMMacIsolated -VmName $VmName
                    if ($vmMac -and $vmMac -ne '000000000000') {
                        $assignedIP = $thisVmConfig.AssignedIP
                        # Scope must be the /24 that contains AssignedIP -- a VM on a secondary
                        # subnet must reserve in its own scope, not vmOptions.network.
                        $ipOctets = ([string]$assignedIP).Split('.')
                        $scopeId = if ($ipOctets.Count -eq 4) { "$($ipOctets[0]).$($ipOctets[1]).$($ipOctets[2]).0" }
                                   elseif ($thisVmConfig.network) { $thisVmConfig.network }
                                   else { $DeployConfig.vmOptions.network }
                        # Only KEEP an existing reservation for this MAC when it points at the
                        # VM's AssignedIP; a reservation at a different IP is stale and would put
                        # the VM on the wrong address (and collide with that IP's rightful owner).
                        $existing = Get-DHCPReservationIPForMac -ScopeId $scopeId -Mac $vmMac
                        if ($existing -and $existing -eq $assignedIP) {
                            Write-Log "$VmName`: DHCP reservation already exists: $existing (MAC=$vmMac); keeping" -LogOnly
                        }
                        else {
                            if ($existing) {
                                Write-Log "$VmName`: DHCP reservation for MAC=$vmMac points to $existing but AssignedIP is $assignedIP; correcting to avoid an address collision" -LogOnly
                            }
                            Add-DHCPReservationIsolated -ScopeId $scopeId -IPAddress $assignedIP -Mac $vmMac -Description "Reservation for $VmName (Linux)" -PurgeMacFirst
                            Write-Log "$VmName`: DHCP reservation created: $assignedIP (MAC=$vmMac, Scope=$scopeId)" -LogOnly
                            $thisVmConfig | Add-Member -MemberType NoteProperty -Name 'ReservationCreated' -Value $true -Force
                        }
                    }
                    else {
                        Write-Log "$VmName`: MAC not yet assigned (000000000000); DHCP reservation deferred to post-start" -LogOnly
                    }
                }
                catch {
                    Write-Log "$VmName`: Could not create DHCP reservation for $($thisVmConfig.AssignedIP). $_" -Warning
                }
            }
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
                Write-Log "$VmName`: Existing OS disk $osDiskPath could not be removed: $($_.Exception.Message)" -Failure
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
            Write-Log "$VmName`: OS disk copy looks suspect (src=$srcLen dst=$dstLen). Refusing to continue." -Failure
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

            # Start the tap NOW, before Start-VM. Hyper-V is the pipe CLIENT, so with
            # no server listening the whole cloud-init console stream is discarded --
            # capturing at the SSH-readiness timeout 30min later would get nothing.
            # Separate process (not a job) so it cannot leak a runspace into ours, and
            # -ExitAfterMinutes so nothing has to chase it if we die first.
            try {
                $tapScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-LinuxSerialTap.ps1'
                if (Test-Path $tapScript) {
                    $tapProc = Start-Process -FilePath (Get-Process -Id $PID).Path `
                        -ArgumentList @('-NoProfile', '-File', "`"$tapScript`"", '-VmName', $VmName, '-ExitAfterMinutes', '60', '-NoConsoleEcho') `
                        -WindowStyle Hidden -PassThru -ErrorAction Stop
                    Write-Log "$VmName`: serial console recorder started (pid $($tapProc.Id)) -> logs\linux-serial\$VmName.log" -LogOnly
                }
            }
            catch {
                Write-Log "$VmName`: could not start serial console recorder: $($_.Exception.Message)" -Warning -LogOnly
            }
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

            # Workgroup (non-domain-joined) Linux VMs get a local human-logon
            # account named after adminName (default 'admin'), mirroring the
            # Windows workgroup model. Domain-joined VMs use domain accounts
            # (adminName/domainUser are in AD), so skip the local one there to
            # avoid shadowing the domain account via NSS (files before sss).
            $vmJoinsDomain = $thisVm -and ($thisVm.PSObject.Properties.Name -contains 'joinDomain') -and [bool]$thisVm.joinDomain
            if (-not $vmJoinsDomain -and $DeployConfig.vmOptions.adminName) {
                $seedArgs.LocalAdminUser = $DeployConfig.vmOptions.adminName
            }

            # Use pre-allocated AssignedIP as static cloud-init IP for all
            # Linux VMs. This means the VM boots with its reserved IP from
            # the very first DHCP request (or statically via netplan), so
            # there's never a window where it has a different address.
            if ($thisVm -and $thisVm.AssignedIP) {
                $netBase = $thisVm.network
                if (-not $netBase) { $netBase = $DeployConfig.vmOptions.network }
                if ($netBase -match '^(\d+\.\d+\.\d+)\.\d+$') {
                    $base = $Matches[1]
                    $seedArgs.StaticIPv4 = $thisVm.AssignedIP
                    $seedArgs.Gateway = "$base.200"
                    Write-Log "$VmName`: Using pre-assigned static IP $($seedArgs.StaticIPv4) (gw $($seedArgs.Gateway))"
                }
                else {
                    Write-Log "$VmName`: Network '$netBase' isn't /24 a.b.c.0 form; falling back to DHCP" -Warning
                }
            }
            elseif ($thisVm -and $thisVm.role -eq 'Proxy') {
                # Fallback for Proxy if AssignedIP wasn't set (shouldn't happen normally)
                $netBase = $thisVm.network
                if (-not $netBase) { $netBase = $DeployConfig.vmOptions.network }
                if ($netBase -match '^(\d+\.\d+\.\d+)\.\d+$') {
                    $base = $Matches[1]
                    $seedArgs.StaticIPv4 = "$base.2"
                    $seedArgs.Gateway = "$base.200"
                    Write-Log "$VmName`: Proxy fallback; pinning to $($seedArgs.StaticIPv4) (gw $($seedArgs.Gateway))"
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

        # Create DHCP reservation now that VM is started and has a real MAC.
        if ($DeployConfig) {
            $thisVmConfig2 = $DeployConfig.virtualMachines | Where-Object { $_.vmName -eq $VmName } | Select-Object -First 1
            if ($thisVmConfig2 -and $thisVmConfig2.AssignedIP -and -not $thisVmConfig2.ReservationCreated) {
                # DHCP/Hyper-V CIM calls run isolated so they don't poison the bars.
                try {
                    $vmMac2 = Get-VMMacIsolated -VmName $VmName
                    if ($vmMac2 -and $vmMac2 -ne '000000000000') {
                        # Scope must be the /24 that contains AssignedIP -- a VM on a secondary
                        # subnet must reserve in its own scope, not vmOptions.network.
                        $ipOctets2 = ([string]$thisVmConfig2.AssignedIP).Split('.')
                        $scopeId2 = if ($ipOctets2.Count -eq 4) { "$($ipOctets2[0]).$($ipOctets2[1]).$($ipOctets2[2]).0" }
                                    elseif ($thisVmConfig2.network) { $thisVmConfig2.network }
                                    else { $DeployConfig.vmOptions.network }
                        # Only KEEP an existing reservation for this MAC when it points at the
                        # VM's AssignedIP; a reservation at a different IP is stale and would put
                        # the VM on the wrong address (and collide with that IP's rightful owner).
                        $existing2 = Get-DHCPReservationIPForMac -ScopeId $scopeId2 -Mac $vmMac2
                        if ($existing2 -and $existing2 -eq $thisVmConfig2.AssignedIP) {
                            Write-Log "$VmName`: DHCP reservation already exists: $existing2 (MAC=$vmMac2); keeping" -LogOnly
                        }
                        else {
                            if ($existing2) {
                                Write-Log "$VmName`: DHCP reservation for MAC=$vmMac2 points to $existing2 but AssignedIP is $($thisVmConfig2.AssignedIP); correcting to avoid an address collision" -LogOnly
                            }
                            Add-DHCPReservationIsolated -ScopeId $scopeId2 -IPAddress $thisVmConfig2.AssignedIP -Mac $vmMac2 -Description "Reservation for $VmName (Linux)" -LogContext $VmName -PurgeMacFirst
                            Write-Log "$VmName`: DHCP reservation created post-start: $($thisVmConfig2.AssignedIP) (MAC=$vmMac2, Scope=$scopeId2)" -LogOnly
                        }
                    }
                }
                catch {
                    # Add-DHCPReservationIsolated already logs each attempt and rethrows
                    # with the full exception chain on final failure; surface a concise
                    # WARN here plus the script stack for diagnostic completeness.
                    $exType = $_.Exception.GetType().FullName
                    $exMsg  = $_.Exception.Message
                    Write-Log "$VmName`: Could not create DHCP reservation post-start for $($thisVmConfig2.AssignedIP) [$exType]: $exMsg" -Warning
                    if ($_.ScriptStackTrace) { Write-Log "$VmName`: DHCP reservation failure stack: $($_.ScriptStackTrace)" -LogOnly }
                }
            }
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
        All Linux VMs now get a pre-assigned static IP via
        Set-DeployConfigIPAddresses (stamped as AssignedIP on the VM
        config). The seed ISO emits a static netplan config using this IP.

        Falls back to the legacy Proxy -> <network>.2 logic if
        AssignedIP is not set (e.g. existing-VM reruns).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [psobject]$VmObject,

        [Parameter(Mandatory = $false)]
        [psobject]$DeployConfig
    )

    if (-not $VmObject) { return $null }

    # Pre-assigned IP from Set-DeployConfigIPAddresses
    if ($VmObject.AssignedIP) { return $VmObject.AssignedIP }

    # Legacy fallback for Proxy
    if ($VmObject.role -eq 'Proxy') {
        $netBase = $VmObject.network
        if (-not $netBase -and $DeployConfig) { $netBase = $DeployConfig.vmOptions.network }
        if ($netBase -match '^(\d+\.\d+\.\d+)\.\d+$') {
            return "$($Matches[1]).2"
        }
    }
    return $null
}

function Get-LinuxVmWaitTimeout {
    <#
    .SYNOPSIS
        Return the SSH-ready timeout (in seconds) for a Linux VM.

    .DESCRIPTION
        Base timeout is 900s (15 min). On large deploys (>10 VMs), disk
        I/O contention from concurrent Windows VM boots / DSC / sysprep
        can delay the Linux VM's cloud-init reboot significantly. Each
        VM above 10 adds 60s to the budget, capped at 2700s (45 min).

        SSH-ready means sshd is listening and the IP is published via
        KVP (or matches the expected static IP for the role). sshd
        starts in cloud-init's `config` stage, which is long before
        `final`/runcmd runs the slow add-on installs (xfce4 + xrdp +
        Firefox for enableRDP, realmd stack for joinDomain). So those
        add-ons should NOT push past the base budget for the SSH-ready
        check itself.

        The scaling addresses the observed failure where a 37-VM deploy
        caused the Proxy VM's post-cloud-init reboot to take >15 min
        under I/O pressure, and the mid-wait power-cycle at 8 min reset
        boot progress, exhausting the remaining 7 min.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [psobject]$VmObject,

        # Total VM count in the deploy. When >10, the timeout scales
        # to accommodate host I/O contention from concurrent VM boots.
        [Parameter(Mandatory = $false)]
        [int]$VmCount = 0
    )

    $base = 900
    if ($VmCount -gt 10) {
        $base = [Math]::Min($base + ($VmCount - 10) * 60, 2700)
    }
    return $base
}

function Get-LinuxGuestActivitySnapshot {
    <#
    .SYNOPSIS
        Host-side sample of whether a Linux guest is doing any work.

    .DESCRIPTION
        Every in-guest liveness signal we have -- sshd on TCP/22, the Hyper-V
        heartbeat IC, the KVP-reported IP -- comes up LATE in a Linux first
        boot, after systemd, hv_utils and cloud-init. Under heavy host I/O a
        healthy guest can be many minutes away from all three, so "none of them
        answered yet" does not mean the guest is dead. Wacky-A 2026-08-16
        power-cycled ZZ-TOFU and ZZ-SQUID on exactly that reasoning
        (heartbeat='LostCommunication' at 890s) and discarded their boot progress.

        These counters need nothing inside the guest: the hypervisor bills the
        virtual processors, the VHDX grows as the guest writes, and the serial
        tap file grows as it prints. A guest that is merely slow still moves
        them; a wedged guest does not.

        Every probe is independently guarded and reports $null when it could not
        be read. $null means UNKNOWN, never idle -- see Test-LinuxGuestActivityMoved.
        Returns $null overall only when the VM itself cannot be read.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    $vm = $null
    try { $vm = Get-VM -Name $VmName -ErrorAction Stop } catch { return $null }
    if (-not $vm) { return $null }

    # Cumulative virtual-processor run time is the strongest signal: monotonic
    # and precise, so it still moves for a guest starved down to a few ms/s.
    # (Get-VM).CPUUsage cannot do that job alone -- it is an integer percent of
    # the WHOLE host, so a 2-vCPU guest crawling on a 16-core host rounds to 0,
    # which is exactly the guest we must not plug-pull.
    $cpuRunTime = $null
    try {
        $wql = "Name LIKE '{0}:Hv VP%'" -f ($VmName -replace "'", "''")
        $vps = @(Get-CimInstance -ClassName Win32_PerfRawData_HvStats_HyperVHypervisorVirtualProcessor -Filter $wql -ErrorAction Stop)
        if ($vps.Count -gt 0) {
            $tot = [double]0
            foreach ($vp in $vps) { $tot += [double]$vp.PercentTotalRunTime }
            $cpuRunTime = $tot
        }
    }
    catch { $cpuRunTime = $null }

    $cpuPercent = $null
    try { $cpuPercent = [int]$vm.CPUUsage } catch { $cpuPercent = $null }

    $hb = $null
    try { $hb = "$($vm.Heartbeat)" } catch { $hb = $null }

    # NTFS can hold back LastWriteTime while a handle is open, so treat the
    # VHDX as a corroborating signal only -- never the sole basis for a verdict.
    $diskBytes = $null
    $diskWriteTicks = $null
    try {
        $seen = 0
        $sum = [long]0
        $newest = [long]0
        foreach ($d in @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop)) {
            if (-not $d.Path) { continue }
            $fi = Get-Item -LiteralPath $d.Path -ErrorAction SilentlyContinue
            if (-not $fi) { continue }
            $seen++
            $sum += [long]$fi.Length
            if ($fi.LastWriteTimeUtc.Ticks -gt $newest) { $newest = $fi.LastWriteTimeUtc.Ticks }
        }
        if ($seen -gt 0) { $diskBytes = $sum; $diskWriteTicks = $newest }
    }
    catch { $diskBytes = $null; $diskWriteTicks = $null }

    $serialBytes = $null
    try {
        $serialLog = Join-Path (Split-Path $PSScriptRoot -Parent) "logs\linux-serial\$VmName.log"
        $sfi = Get-Item -LiteralPath $serialLog -ErrorAction SilentlyContinue
        if ($sfi) { $serialBytes = [long]$sfi.Length }
    }
    catch { $serialBytes = $null }

    return [pscustomobject]@{
        State          = "$($vm.State)"
        Heartbeat      = $hb
        CpuRunTime     = $cpuRunTime
        CpuPercent     = $cpuPercent
        DiskBytes      = $diskBytes
        DiskWriteTicks = $diskWriteTicks
        SerialBytes    = $serialBytes
    }
}

function Get-LinuxGuestActivityReadable {
    <#
    .SYNOPSIS
        Names of the activity signals that actually returned a value.

    .DESCRIPTION
        A stall verdict derived from probes that all failed to read is a
        measurement of nothing dressed up as a measurement of zero. Callers log
        this so a run where every probe was blind is visible as such instead of
        looking like a confident "guest is idle".
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [psobject]$Snapshot
    )

    if ($null -eq $Snapshot) { return @() }
    $names = @()
    foreach ($p in 'CpuRunTime', 'CpuPercent', 'DiskBytes', 'DiskWriteTicks', 'SerialBytes') {
        if ($null -ne $Snapshot.$p) { $names += $p }
    }
    return $names
}

function Get-LinuxGuestActivityDelta {
    <#
    .SYNOPSIS
        Compare two activity snapshots and report whether the guest did real work.

    .DESCRIPTION
        The first version of this asked "did any counter CHANGE", which can never
        report a stall: PercentTotalRunTime is a CUMULATIVE 100ns counter and the
        VHDX mtime advances on any flush, so both move for a VM that is merely
        powered on. ZZ-TOFU sat 1310s past the restart floor on 2026-08-17 with the
        stall clock resetting on every sample, so its retry never fired at all.

        So the counters become RATES measured against floors:
          CpuBusyPercent  - percent of ONE virtual processor, summed across VPs
          DiskGrowthBytes - dynamic VHDX growth over the window
          SerialGrowth    - bytes the guest printed to the console
        DiskWriteTicks stays in the snapshot for the log but is deliberately NOT a
        decision input: it moves on any flush, guest work or not.

        Fails SAFE in both directions -- no comparable sample, or nothing readable
        on both ends, yields Moved=$true. Only a measured, all-below-floor window
        yields $false, and .Why always carries the numbers behind the verdict so
        the decision can be audited from the build log.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [psobject]$Previous,

        [Parameter(Mandatory = $false)]
        [psobject]$Current,

        [Parameter(Mandatory = $false)]
        [double]$ElapsedSeconds = 0,

        # Percent of one virtual processor. A guest blocked on starved I/O sits
        # near 0; anything genuinely booting is far above this.
        [Parameter(Mandatory = $false)]
        [double]$CpuBusyFloorPercent = 2.0,

        [Parameter(Mandatory = $false)]
        [long]$DiskGrowthFloorBytes = 1MB
    )

    $r = [ordered]@{
        Moved             = $true
        Why               = 'unknown'
        CpuBusyPercent    = $null
        DiskGrowthBytes   = $null
        SerialGrowthBytes = $null
        Heartbeat         = $null
        Measured          = @()
    }

    if ($null -eq $Previous -or $null -eq $Current) {
        $r.Why = 'no comparable sample yet'
        return [pscustomobject]$r
    }
    $r.Heartbeat = "$($Current.Heartbeat)"
    if ($ElapsedSeconds -le 0) {
        $r.Why = 'zero-length window'
        return [pscustomobject]$r
    }
    if ("$($Current.Heartbeat)" -like 'Ok*') {
        $r.Why = "heartbeat='$($Current.Heartbeat)'"
        return [pscustomobject]$r
    }

    $measured = [System.Collections.Generic.List[string]]::new()

    $busy = $null
    if ($null -ne $Previous.CpuRunTime -and $null -ne $Current.CpuRunTime) {
        $d = [double]$Current.CpuRunTime - [double]$Previous.CpuRunTime
        if ($d -lt 0) { $d = 0 }  # counter restarts with the VM across a power-cycle
        $busy = [math]::Round(($d / ($ElapsedSeconds * 1e7)) * 100, 2)
        $measured.Add('cpu')
    }
    elseif ($null -ne $Current.CpuPercent) {
        $busy = [double]$Current.CpuPercent
        $measured.Add('cpu%')
    }
    $r.CpuBusyPercent = $busy

    $disk = $null
    if ($null -ne $Previous.DiskBytes -and $null -ne $Current.DiskBytes) {
        $disk = [long]$Current.DiskBytes - [long]$Previous.DiskBytes
        if ($disk -lt 0) { $disk = 0 }
        $measured.Add('disk')
    }
    $r.DiskGrowthBytes = $disk

    $serial = $null
    if ($null -ne $Previous.SerialBytes -and $null -ne $Current.SerialBytes) {
        $serial = [long]$Current.SerialBytes - [long]$Previous.SerialBytes
        if ($serial -lt 0) { $serial = 0 }
        $measured.Add('serial')
    }
    $r.SerialGrowthBytes = $serial

    $r.Measured = $measured.ToArray()
    if ($measured.Count -eq 0) {
        $r.Why = 'no signal readable on both samples'
        return [pscustomobject]$r
    }

    $hits = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $busy -and $busy -ge $CpuBusyFloorPercent) { $hits.Add("cpu=$busy% >= $CpuBusyFloorPercent%") }
    if ($null -ne $disk -and $disk -ge $DiskGrowthFloorBytes) { $hits.Add("disk=+$disk B >= $DiskGrowthFloorBytes B") }
    if ($null -ne $serial -and $serial -gt 0) { $hits.Add("serial=+$serial B") }

    $cpuTxt = $(if ($null -ne $busy) { "$busy%" } else { 'n/a' })
    $diskTxt = $(if ($null -ne $disk) { "+$disk B" } else { 'n/a' })
    $serialTxt = $(if ($null -ne $serial) { "+$serial B" } else { 'n/a' })

    if ($hits.Count -gt 0) {
        $r.Moved = $true
        $r.Why = ($hits -join ', ')
    }
    else {
        $r.Moved = $false
        $r.Why = "below floors over ${ElapsedSeconds}s: cpu=$cpuTxt (floor $CpuBusyFloorPercent%) disk=$diskTxt (floor $DiskGrowthFloorBytes B) serial=$serialTxt"
    }
    return [pscustomobject]$r
}

function Get-LinuxHeadStartSeconds {
    <#
    .SYNOPSIS
        Seconds to hold back Windows VM creation so Linux VMs boot first.

    .DESCRIPTION
        Widening the SSH-ready timeout (Get-LinuxVmWaitTimeout) treats the
        symptom; this reduces the contention itself. A small Linux guest
        (Proxy is 1GB/1vCPU) that boots alongside 20+ Windows VMs can be
        starved of host CPU/IO badly enough that it never reaches userspace
        -- PL-OREGANO booted the kernel and never wrote a single log line.

        Linux VMs finish Phase 1 and then sit idle (no DSC phases 3-9), so
        a head start costs little: the Windows VMs it delays go on to run
        far longer phases anyway.

        Returns 0 when there is nothing to protect (no Linux VMs) or the
        deploy is small enough that contention is not a factor.

        SIZING: the window has to cover a Linux FIRST BOOT, not just the VM
        creation call. Observed cold-build SSH-ready times on LABHOST are
        ~550s quiet / >1680s under a 22-VHDX copy storm, so the original
        10s/VM capped at 300s (= 150s for a 23-VM deploy) protected only the
        first tenth of what it was aimed at, and Wacky-A 2026-08-16 lost
        ZZ-TOFU with all 19 Windows copies landing mid-boot. 20s/VM capped at
        600s gives 300s at 23 VMs and 580s at 37.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [psobject]$DeployConfig,

        # Deploys at or below this many VMs get no delay.
        [Parameter(Mandatory = $false)]
        [int]$Threshold = 8,

        [Parameter(Mandatory = $false)]
        [int]$SecondsPerVm = 20,

        [Parameter(Mandatory = $false)]
        [int]$MaxSeconds = 600
    )

    $vms = @($DeployConfig.virtualMachines)
    if ($vms.Count -le $Threshold) { return 0 }
    if (-not ($vms | Where-Object { Test-VmIsLinux -Vm $_ })) { return 0 }
    return [Math]::Min(($vms.Count - $Threshold) * $SecondsPerVm, $MaxSeconds)
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

function Wait-LinuxCloudInitComplete {
    <#
    .SYNOPSIS
        After SSH is up, block until cloud-init reaches a terminal state so we
        never run apt while cloud-init's first-boot 'packages:' step is still
        going.

    .DESCRIPTION
        Wait-LinuxVmReady returns the instant sshd answers, but on first boot
        cloud-init is often still running its package install AND has a
        'power_state: reboot (delay: now)' queued for when its modules finish.
        If we start Phase-2 apt in that window, cloud-init's reboot fires
        mid-apt and the in-flight dpkg write is lost (ext4 delayed allocation:
        /var/lib/dpkg/status keeps its size but its data blocks are never
        flushed), leaving the DB all-NUL -> "parsing file '.../status' near
        line 0: end of file" and the debconf/apt cascade. This gates apt on
        cloud-init being done.

        Polls 'cloud-init status' over short SSH commands so a power_state
        reboot mid-wait is tolerated (SSH drops -> we keep polling until it's
        back and reports done). Proceeds (with a warning) on error/degraded or
        on timeout -- cloud-init trouble shouldn't hard-block the deploy, and
        the apt path has its own recovery.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [int]$TimeoutSeconds = 600
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastState = $null
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $r = Invoke-LinuxVmCommand -VmName $VmName -IPAddress $IPAddress -SuppressLog `
            -Sudo -TimeoutSeconds 20 -DisplayName "cloud-init status" `
            -BashCommand 'cloud-init status 2>/dev/null || echo "status: unknown"'
        $state = ""
        if ($r -and -not $r.ScriptBlockFailed -and $r.ScriptBlockOutput -match 'status:\s*(\S+)') {
            $state = $Matches[1].Trim().ToLower()
        }
        if ($state -in @('done', 'error', 'degraded', 'disabled')) {
            $elapsed = [int]$sw.Elapsed.TotalSeconds
            if ($state -eq 'done') {
                Write-Log "$VmName`: cloud-init done (waited ${elapsed}s)" -LogOnly
            }
            else {
                Write-Log "$VmName`: cloud-init finished with status '$state' (waited ${elapsed}s); proceeding" -Warning
            }
            return $true
        }
        if ($state -ne $lastState) {
            $lastState = $state
            $elapsed = [int]$sw.Elapsed.TotalSeconds
            $disp = if ($state) { $state } else { "unreachable (rebooting?)" }
            Write-Log "$VmName`: cloud-init status: $disp (${elapsed}s)" -LogOnly
        }
        # Update the phase progress line every poll so it visibly ticks while we
        # wait (cloud-init sits in 'running' for minutes; a state-change-only
        # update would look frozen).
        $elapsedNow = [int]$sw.Elapsed.TotalSeconds
        $dispNow = if ($state) { $state } else { "unreachable (rebooting?)" }
        write-progress2 "Wait for Linux VM" -Status "$VmName`: waiting for cloud-init to finish (status: $dispNow, ${elapsedNow}s / ${TimeoutSeconds}s)" -force
        Start-Sleep -Seconds 8
    }
    Write-Log "$VmName`: cloud-init still not done after ${TimeoutSeconds}s; proceeding anyway" -Warning
    return $false
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
        [string]$ExpectedIPAddress,

        # A guest is only declared dead after EVERY host-visible activity
        # counter has been flat for this long. Replaces the old "53% of the
        # budget has elapsed" rule, which fired on wall-clock alone and so
        # scaled with host load in exactly the wrong direction.
        [Parameter(Mandatory = $false)]
        [int]$StallSeconds = 300,

        # Power-cycles allowed per wait. A guest can wedge again on the retry
        # boot (ZZ-TOFU wedged on both of its boots on 2026-08-16) and the old
        # single-shot latch left the remaining budget burning against a guest
        # nothing was going to recover.
        [Parameter(Mandatory = $false)]
        [int]$MaxRestarts = 2,

        # Minimum gap between power-cycles, so a retry boot gets a real chance
        # before the next trigger is even evaluated.
        [Parameter(Mandatory = $false)]
        [int]$RestartCooldownSeconds = 300
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
    $restartAfterSec = [int]($TimeoutSeconds * 0.53)  # earliest a power-cycle may be considered; the stall test still has to agree
    # Track whether the guest has shown any sign of life (sshd accepted a
    # TCP/22 connection at least once). A VM that is merely slow to finish
    # cloud-init under heavy host I/O load looks "stuck" to the restart
    # heuristic, but power-cycling it just discards boot progress and
    # restarts the cold-boot clock — exactly the wrong move under load.
    # We only power-cycle VMs that have NEVER shown sshd listening.
    $sawSignOfLife = $false

    # Host-visible activity tracking. $restartAfterSec is now only the EARLIEST
    # moment a power-cycle may be considered; the decision itself needs
    # $StallSeconds of proven inactivity on top of it, so a guest that is
    # merely crawling under I/O contention is never plug-pulled.
    $restartCount = 0
    $nextRestartAllowedSec = 0
    $lastActivitySampleSec = 0
    $lastActivityLogSec = -9999
    $lastActivityWhy = 'not sampled yet'
    # KVP reporting an IP proves the guest reached userspace far enough to run
    # hv_kvp_daemon, so the backstop below must not fire once we have seen one.
    $sawKvpIp = $false
    $lastActivity = Get-LinuxGuestActivitySnapshot -VmName $VmName
    $lastActivityAt = Get-Date
    $activitySignals = @(Get-LinuxGuestActivityReadable -Snapshot $lastActivity)
    if ($activitySignals.Count -eq 0) {
        # Not fatal, but it means the stall detector is blind and will never
        # authorise a power-cycle. Say so rather than let it look like a pass.
        Write-Log "$VmName`: no host-visible activity counters readable — stall detection is BLIND; will wait out the full budget instead of power-cycling." -Warning
    }
    else {
        Write-Log "$VmName`: activity signals available: $($activitySignals -join ', ')" -LogOnly
    }

    # Emit the serial console tail into the build log. Called at the power-cycle
    # decision as well as the final timeout: the 08-06 stress run cycled OREGANO at
    # 954s and the job ended before the 1800s timeout, so a timeout-only harvest
    # captured nothing on the one run where the capture was actually running.
    $emitSerialTail = {
        param([string]$Reason)
        try {
            $serialLog = Join-Path (Split-Path $PSScriptRoot -Parent) "logs\linux-serial\$VmName.log"
            if (-not (Test-Path $serialLog)) {
                Write-Log "$VmName`: no serial console capture at $serialLog ($Reason)" -LogOnly
                return
            }
            $info = Get-Item $serialLog
            $ageMin = [int]((Get-Date) - $info.LastWriteTime).TotalMinutes
            Write-Log "$VmName`: serial console capture at $Reason -- $($info.Length) bytes, last written $($info.LastWriteTime.ToString('HH:mm:ss')) (${ageMin}m ago)" -LogOnly
            $tail = @(Get-Content $serialLog -Tail 60 -ErrorAction SilentlyContinue | Where-Object { "$_".Trim() })
            foreach ($sl in $tail) {
                Write-Log "$VmName`:   serial> $("$sl" -replace '\x1b\[[0-9;?]*[A-Za-z]', '' -replace '[^\x20-\x7E]', '')" -LogOnly
            }
            $bad = @($tail | Where-Object { $_ -match 'cloud-init.*(fail|error|Traceback)|Failed to start|dependency failed' })
            if ($bad) { Write-Log "$VmName`: serial console shows cloud-init/systemd failure: $($bad[0])" -Warning }
        }
        catch {
            Write-Log "$VmName`: serial console capture failed: $($_.Exception.Message)" -LogOnly
        }
    }
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
            $sawKvpIp = $true
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
            $tcpLabel = $(if ($tcpProbeOk) { 'tcp/22 open' } else { 'tcp/22 closed' })
            if ($tcpProbeOk) { $sawSignOfLife = $true }
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
                write-progress2 "Wait for Linux VM" -Status "$VmName`: SSH ready at $ip" -force
                # SSH is up, but on first boot cloud-init may still be running its
                # 'packages:' step with a queued power_state reboot. Don't return
                # (and let the caller start apt) until cloud-init is done -- its
                # reboot firing mid-apt is what zeroes the dpkg status DB.
                $null = Wait-LinuxCloudInitComplete -VmName $VmName -IPAddress $ip -TimeoutSeconds ([Math]::Min(600, $TimeoutSeconds))
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

        # ── Activity sampling. Sampled on its own cadence (not every poll) so
        # the CIM/Hyper-V queries stay cheap with several Linux VMs in flight.
        if ($elapsed - $lastActivitySampleSec -ge 30) {
            $windowSec = $elapsed - $lastActivitySampleSec
            $lastActivitySampleSec = $elapsed
            $nowAct = Get-LinuxGuestActivitySnapshot -VmName $VmName
            $delta = Get-LinuxGuestActivityDelta -Previous $lastActivity -Current $nowAct -ElapsedSeconds $windowSec
            $lastActivityWhy = $delta.Why
            if ($delta.Moved) { $lastActivityAt = Get-Date }
            # Logged on a slow cadence even when nothing is wrong: without the
            # actual rates in the log there is no way to calibrate the floors,
            # and no way to explain afterwards why a cycle did or did not fire.
            if ($elapsed - $lastActivityLogSec -ge 120) {
                $lastActivityLogSec = $elapsed
                Write-Log "$VmName`: activity @${elapsed}s moved=$($delta.Moved) measured=[$($delta.Measured -join ',')] $($delta.Why)" -LogOnly
            }
            if ($null -ne $nowAct) { $lastActivity = $nowAct }
        }
        $stalledSec = [int]((Get-Date) - $lastActivityAt).TotalSeconds

        # ── Mid-wait restart. Two independent triggers:
        #
        # STALL: every measurable activity rate below its floor for $StallSeconds.
        # Fires early and only when the counters actually say so.
        #
        # BACKSTOP: 70% of the budget gone with sshd never seen AND KVP never
        # reporting an IP. This exists because the stall test is only as good as
        # its instruments, and on 2026-08-17 it was not good at all -- it was
        # comparing cumulative counters that advance for any powered-on VM, so it
        # never fired and ZZ-TOFU silently lost the retry the old wall-clock rule
        # used to give it. A watchdog whose only trigger depends on an instrument
        # is one bad instrument away from doing nothing, so the backstop
        # deliberately depends on nothing but the clock and two facts that are
        # hard evidence of a guest that never reached userspace.
        #
        # A hard -TurnOff is a plug-pull: pulling it while dpkg is writing
        # /var/lib/dpkg/status truncates it and permanently breaks apt on the VM.
        # That is why the stop below is graceful first, TurnOff only as fallback.
        $backstopAfterSec = [int]($TimeoutSeconds * 0.70)
        $stallDue = ($elapsed -ge $restartAfterSec -and -not $sawSignOfLife -and $stalledSec -ge $StallSeconds)
        $backstopDue = ($elapsed -ge $backstopAfterSec -and -not $sawSignOfLife -and -not $sawKvpIp)

        # Without this the backstop conditions are still true on the very next
        # poll and both restarts would be spent inside 20 seconds, before the
        # retry boot has had any chance at all.
        $cooldownOk = ($elapsed -ge $nextRestartAllowedSec)

        if ($restartCount -lt $MaxRestarts -and $cooldownOk -and ($stallDue -or $backstopDue)) {
            $hb = "$($lastActivity.Heartbeat)"
            $doCycle = $false
            $reason = ''

            if ($backstopDue) {
                $doCycle = $true
                $reason = "backstop: ${elapsed}s of ${TimeoutSeconds}s, sshd never answered and KVP never reported an IP (heartbeat='$hb', last activity: $lastActivityWhy)"
            }
            else {
                # Host still mid base-image copy storm? Those robocopy streams are
                # what starves the guest in the first place, so require twice the
                # quiet before blaming the guest. Only the stall path defers --
                # the backstop must not be postponable or it stops being a net.
                $busyCopies = 0
                try { $busyCopies = @(Get-Process -Name 'robocopy' -ErrorAction SilentlyContinue).Count } catch { $busyCopies = 0 }
                $effectiveStall = $(if ($busyCopies -gt 0) { $StallSeconds * 2 } else { $StallSeconds })
                $readable = @(Get-LinuxGuestActivityReadable -Snapshot $lastActivity)

                if ($readable.Count -eq 0) {
                    Write-Log "$VmName`: ${stalledSec}s with no SSH, but NO activity counter was readable — leaving the decision to the backstop at ${backstopAfterSec}s." -Warning
                }
                elseif ($stalledSec -lt $effectiveStall) {
                    Write-Log "$VmName`: flat for ${stalledSec}s but $busyCopies base-image copy/copies still running — holding off until ${effectiveStall}s of quiet." -LogOnly
                }
                else {
                    $doCycle = $true
                    $reason = "no measurable activity for ${stalledSec}s on [$($readable -join ', ')] (heartbeat='$hb', copies=$busyCopies, $lastActivityWhy)"
                }
            }

            if ($doCycle) {
                $restartCount++
                $nextRestartAllowedSec = $elapsed + $RestartCooldownSeconds
                Write-Log "$VmName`: power-cycle $restartCount of $MaxRestarts — $reason" -Warning

                # Capture BEFORE the stop: this is the moment we declare the guest dead,
                # and a TurnOff destroys whatever the console was about to tell us.
                & $emitSerialTail 'power-cycle decision'
                write-progress2 "Wait for Linux VM" -Status "$VmName`: restarting VM (no SSH after ${elapsed}s)..." -force
                try {
                    # Try a GRACEFUL shutdown first (systemd stops apt/dpkg
                    # cleanly and flushes the filesystem to the VHDX). Only fall
                    # back to a hard -TurnOff if the guest won't stop within 60s
                    # (truly wedged), so we never plug-pull a guest that could
                    # still be flushing a pending dpkg write.
                    $stopped = $false
                    try { Stop-VM -Name $VmName -Force -ErrorAction Stop -WarningAction SilentlyContinue } catch { }
                    for ($si = 0; $si -lt 30; $si++) {
                        if ((Get-VM -Name $VmName -ErrorAction SilentlyContinue).State -eq 'Off') { $stopped = $true; break }
                        Start-Sleep -Seconds 2
                    }
                    if (-not $stopped) {
                        Write-Log "$VmName`: graceful shutdown didn't complete in 60s; forcing TurnOff (guest wedged)" -Warning
                        Stop-VM -Name $VmName -TurnOff -Force -ErrorAction Stop
                    }
                    Start-Sleep -Seconds 3
                    Start-VM -Name $VmName -ErrorAction Stop
                    Write-Log "$VmName`: VM restarted (graceful=$stopped); resuming SSH poll with $([int](($deadline - (Get-Date)).TotalSeconds))s remaining"
                }
                catch {
                    Write-Log "$VmName`: VM restart failed: $($_.Exception.Message)" -Warning
                }
                # Reset tracking so the loop re-discovers the IP cleanly
                $lastReportedIp = $null
                $loggedKnownHostsForIp = $null
                $lastHeartbeatSec = $elapsed
                # The retry boot gets a fresh stall window; without this reset
                # the already-expired one would re-fire on the next sample and
                # spend every remaining restart in a single burst.
                $lastActivity = $null
                $lastActivityAt = Get-Date
                $lastActivitySampleSec = $elapsed
            }
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }

    Write-Log "$VmName`: Timeout waiting for Linux VM SSH readiness (${TimeoutSeconds}s)" -Failure

    # The SSH autopsy below can only say sshd never answered. WHY it never
    # answered is on the serial console -- cloud-init writes its failures there
    # and nowhere the host can reach once the lab is torn down.
    & $emitSerialTail 'SSH-readiness timeout'

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
                $uptime = $(if ($vm.Uptime) { [int]$vm.Uptime.TotalSeconds } else { 0 })
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
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [string]$UserName = 'vmbuildadmin'
    )

    if (-not $DisplayName) {
        $DisplayName = $(if ($BashCommand.Length -gt 80) { $BashCommand.Substring(0, 77) + '...' } else { $BashCommand })
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
    $remoteShell = $(if ($Sudo.IsPresent) { 'sudo -n bash -s' } else { 'bash -s' })

    # See Wait-LinuxVmReady probe comment: ignore host keys for internal SSH.
    # Stale known_hosts from a prior deploy with the same IP silently breaks
    # all subsequent ops; lab vSwitch traffic is host-only so MITM risk is nil.
    $sshArgs = @(
        '-i', $keyPair.PrivateKeyPath,
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=NUL',
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=60',
        '-o', "ServerAliveInterval=$([Math]::Max(15, [int]($TimeoutSeconds / 4)))",
        '-o', 'LogLevel=ERROR',
        "$UserName@$IPAddress",
        $remoteShell
    )

    # Retry loop: SSH exit code 255 = transport-level failure (connection
    # refused, network unreachable, connection reset). These are transient
    # during VM boot, service restarts, and VMBus hiccups. Retry up to 3
    # times with increasing backoff. Non-255 exit codes (remote command
    # failures) are never retried -- the remote script ran and failed.
    $maxSshRetries = 3
    $sshAttempt = 0

    :sshRetry while ($true) {
    $sshAttempt++
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
            # Exit code 255 = SSH transport failure (connection refused, reset,
            # network unreachable). Retry if we haven't exhausted attempts.
            if ($proc.ExitCode -eq 255 -and $sshAttempt -lt $maxSshRetries) {
                $backoff = $sshAttempt * 10
                if (-not $SuppressLog) {
                    Write-Log "$VmName`: SSH connection failed (attempt $sshAttempt/$maxSshRetries), retrying in ${backoff}s..." -Warning
                }
                Start-Sleep -Seconds $backoff
                # Reset return object for next attempt
                $return.ScriptBlockFailed = $false
                $return.ScriptBlockOutput = $null
                $return.ExitCode = -1
                continue sshRetry
            }

            $return.ScriptBlockFailed = $true
            $combined = $stdout
            if ($stderr) {
                if ($combined) { $combined += "`n" }
                $combined += $stderr
            }
            $return.ScriptBlockOutput = $combined
            if (-not $SuppressLog) {
                $excerpt = $(if ($combined) { ($combined -replace "`r`n", "`n").Trim() } else { '(no output)' })
                if ($excerpt.Length -gt 400) { $excerpt = $excerpt.Substring(0, 400) + '...' }
                Write-Log "$VmName`: '$DisplayName' failed (exit=$($proc.ExitCode)): $excerpt" -Failure
            }
        }
    }
    catch {
        # Retry on process-level exceptions (e.g. ssh.exe not responding) if
        # we haven't exhausted attempts.
        if ($sshAttempt -lt $maxSshRetries) {
            $backoff = $sshAttempt * 10
            if (-not $SuppressLog) {
                Write-Log "$VmName`: SSH exception (attempt $sshAttempt/$maxSshRetries): $_ -- retrying in ${backoff}s..." -Warning
            }
            Start-Sleep -Seconds $backoff
            $return.ScriptBlockFailed = $false
            $return.ScriptBlockOutput = $null
            $return.ExitCode = -1
            continue sshRetry
        }
        $return.ScriptBlockFailed = $true
        $return.ScriptBlockOutput = "$_"
        if (-not $SuppressLog) {
            Write-Log "$VmName`: Exception running '$DisplayName': $_" -Failure
            Write-Log "$($_.ScriptStackTrace)" -LogOnly
        }
    }
    break sshRetry
    } # end :sshRetry while loop

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

    # Re-run idempotency: a Linux VM is "already flipped" ONLY when its GUEST
    # actually routes the AD domain to the DC -- i.e. the systemd-resolved
    # routing drop-in /etc/systemd/resolved.conf.d/memlabs-dc-route.conf exists
    # and names THIS DC + domain. The old signal (does the DC hold the VM's A
    # record?) was WRONG: a guest can register its own A record while still
    # resolving the domain apex / AD SRV records via PUBLIC DNS (netplan merges
    # the nameserver list so the DC lands last, and a lab domain that collides
    # with a real internet domain answers AD queries with wrong public IPs).
    # That false-positive is exactly what made this Phase 2 flip no-op on an
    # already-broken box. So probe each guest for the route drop-in and skip
    # only VMs that already have it current; any VM we can't confirm falls
    # through to the full flip below (cheap grep, 20s cap, no restart gate).
    try {
        $needFlip = [System.Collections.Generic.List[object]]::new()
        foreach ($vm in $linuxVms) {
            $probeIp = Get-LinuxVmIPAddress -VmName $vm.vmName
            if (-not $probeIp) { $needFlip.Add($vm); continue }
            $routeCheck = "grep -qF `"Domains=~$domain`" /etc/systemd/resolved.conf.d/memlabs-dc-route.conf 2>/dev/null && grep -qF `"DNS=$dcIp`" /etc/systemd/resolved.conf.d/memlabs-dc-route.conf 2>/dev/null && echo OK || echo MISSING"
            $pr = Invoke-LinuxVmCommand -VmName $vm.vmName -IPAddress $probeIp -BashCommand $routeCheck -Sudo -DisplayName "check dc-route.conf" -TimeoutSeconds 20 -SuppressLog
            if ($pr -and -not $pr.ScriptBlockFailed -and "$($pr.ScriptBlockOutput)".Trim() -eq 'OK') {
                Write-Log "Set-LinuxVmsDcDns: $($vm.vmName) already routes '$domain' to DC $dcIp; skipping" -LogOnly
            }
            else {
                $needFlip.Add($vm)
            }
        }
        if ($needFlip.Count -eq 0) {
            Write-Log "Set-LinuxVmsDcDns: All $($linuxVms.Count) Linux VM(s) already route '$domain' to the DC; skipping" -Success
            return $true
        }
        if ($needFlip.Count -lt $linuxVms.Count) {
            Write-Log "Set-LinuxVmsDcDns: $($linuxVms.Count - $needFlip.Count)/$($linuxVms.Count) already routed; processing $($needFlip.Count) remaining" -LogOnly
        }
        $linuxVms = @($needFlip)
    }
    catch {
        Write-Log "Set-LinuxVmsDcDns: Could not pre-check guest DNS routing: $_" -LogOnly
    }

    Write-Log "Set-LinuxVmsDcDns: Pointing $($linuxVms.Count) Linux VM(s) at DC $($dcVm.vmName) ($dcIp / $domain)" -Activity
    $allOk = $true
    foreach ($vm in $linuxVms) {
        # DC-DNS config comes from the shared lib/set-dc-dns.sh (single source of
        # truth, also used by realm-join.sh) instead of the stale baked
        # /usr/local/sbin/memlabs-set-dns helper. Load the memlabs_set_dc_dns
        # function body and invoke it with this DC + domain. Invoke-LinuxVmCommand
        # pipes to `bash -s` over stdin and strips CRLF->LF, so the heredocs inside
        # the function terminate correctly on the guest.
        $cmd = (Get-LinuxScript -Name 'lib/set-dc-dns') + "`nmemlabs_set_dc_dns '$dcIp' '$domain'`n"

        # --- SSH readiness gate --------------------------------------------
        # Phase 1 confirmed SSH, but sshd may have crashed or the VM may
        # have rebooted during the Phase 2 DSC window (Linux VMs idle for
        # 10-20 min while Windows DSC runs). Check heartbeat + tcp/22
        # before burning through the DNS retries; if unreachable, restart
        # the VM once.
        #
        # Timeout: 3 min base + 20s per VM above 10 (matches the scaling
        # pattern used for DSC self-recovery and Wait-LinuxVmReady).
        $vmCount = $linuxVms.Count + @($DeployConfig.virtualMachines | Where-Object { -not (Test-VmIsLinux -Vm $_) -and -not $_.hidden }).Count
        $probeTimeoutSec = 180
        if ($vmCount -gt 10) { $probeTimeoutSec += ($vmCount - 10) * 20 }

        # Quick heartbeat + uptime check: if Hyper-V integration services
        # report no heartbeat the guest OS is down (crashed / stuck at
        # GRUB). Skip straight to restart rather than polling tcp/22 for
        # minutes.  Also capture uptime: a VM with OkApplicationsUnknown
        # heartbeat but >10 min uptime is stuck in boot (hv_utils loaded
        # but sshd never started). In that case a restart is the only fix;
        # extra TCP wait would just burn time.
        $heartbeatHealthy = $false
        $needsRestart = $false
        $vmUptimeSec = 0
        try {
            $vmState = Get-VM -Name $vm.vmName -ErrorAction Stop
            $vmUptimeSec = [int]$vmState.Uptime.TotalSeconds
            if ($vmState.Heartbeat -in 'OkApplicationsHealthy', 'OkApplicationsUnknown') {
                $heartbeatHealthy = $true
                # OkApplicationsUnknown is the normal steady state for Linux
                # VMs — Ubuntu doesn't implement the Hyper-V application
                # heartbeat protocol, so it never reports OkApplicationsHealthy.
                # Don't treat long uptime as "stuck boot"; just use the full
                # probe timeout and let TCP/22 decide.
            }
            elseif ($vmState.Heartbeat) {
                Write-Log "[Linux DNS] $($vm.vmName): heartbeat=$($vmState.Heartbeat) state=$($vmState.State) uptime=${vmUptimeSec}s -- guest not healthy, will restart" -Warning
                $needsRestart = $true
            }
            else {
                Write-Log "[Linux DNS] $($vm.vmName): no heartbeat reported, state=$($vmState.State) uptime=${vmUptimeSec}s -- will restart" -Warning
                $needsRestart = $true
            }
        }
        catch {}

        $vmIpPre = Get-LinuxVmIPAddress -VmName $vm.vmName
        if ($vmIpPre -and -not $needsRestart) {
            $tcpUp = $false
            # If the VM has been running for 10+ minutes, sshd should
            # already be up.  Use a short 60s probe so we restart quickly
            # instead of waiting the full scaled timeout (480s+ in large
            # labs).  The long timeout only makes sense during first boot
            # when cloud-init / dpkg may still be running.
            $effectiveProbe = $probeTimeoutSec
            if ($vmUptimeSec -gt 600) {
                $effectiveProbe = [Math]::Min($effectiveProbe, 60)
                Write-Log "[Linux DNS] $($vm.vmName): uptime ${vmUptimeSec}s, using short ${effectiveProbe}s SSH probe" -LogOnly
            }
            $probeEnd = (Get-Date).AddSeconds($effectiveProbe)
            while (-not $tcpUp -and (Get-Date) -lt $probeEnd) {
                try {
                    $tc = [System.Net.Sockets.TcpClient]::new()
                    $iar = $tc.BeginConnect($vmIpPre, 22, $null, $null)
                    if ($iar.AsyncWaitHandle.WaitOne(3000, $false)) {
                        $tc.EndConnect($iar) | Out-Null
                        $tcpUp = $tc.Connected
                    }
                    $tc.Close()
                }
                catch { }
                if (-not $tcpUp) { Start-Sleep -Seconds 10 }
            }
            if (-not $tcpUp) {
                if ($heartbeatHealthy) {
                    # OS alive (heartbeat OK) but sshd isn't listening yet.
                    # Give it 3 more minutes — sshd may be waiting on
                    # cloud-init, dpkg lock, or entropy. Don't restart a
                    # healthy VM; that resets boot progress.
                    Write-Log "[Linux DNS] $($vm.vmName): tcp/22 not open after ${effectiveProbe}s but heartbeat healthy (uptime ${vmUptimeSec}s) -- waiting 3 more min for sshd" -Warning
                    $extendEnd = (Get-Date).AddSeconds(180)
                    while (-not $tcpUp -and (Get-Date) -lt $extendEnd) {
                        try {
                            $tc = [System.Net.Sockets.TcpClient]::new()
                            $iar = $tc.BeginConnect($vmIpPre, 22, $null, $null)
                            if ($iar.AsyncWaitHandle.WaitOne(3000, $false)) {
                                $tc.EndConnect($iar) | Out-Null
                                $tcpUp = $tc.Connected
                            }
                            $tc.Close()
                        }
                        catch { }
                        if (-not $tcpUp) { Start-Sleep -Seconds 10 }
                    }
                }
                if (-not $tcpUp) {
                    $needsRestart = $true
                }
            }
        }
        elseif (-not $vmIpPre -and -not $needsRestart) {
            # No IP reported yet -- VM may be stuck pre-network.
            $needsRestart = $true
        }

        if ($needsRestart) {
            $reason = if (-not $vmIpPre) { 'no IP reported' } else { "tcp/22 not reachable at $vmIpPre (uptime ${vmUptimeSec}s)" }
            Write-Log "[Linux DNS] $($vm.vmName): $reason. Restarting VM..." -Warning
            Stop-VM -Name $vm.vmName -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
            Start-VM -Name $vm.vmName -ErrorAction SilentlyContinue
            $tcpUp = $false
            $restartEnd = (Get-Date).AddSeconds(180)
            while (-not $tcpUp -and (Get-Date) -lt $restartEnd) {
                $vmIpPre = Get-LinuxVmIPAddress -VmName $vm.vmName
                if ($vmIpPre) {
                    try {
                        $tc = [System.Net.Sockets.TcpClient]::new()
                        $iar = $tc.BeginConnect($vmIpPre, 22, $null, $null)
                        if ($iar.AsyncWaitHandle.WaitOne(3000, $false)) {
                            $tc.EndConnect($iar) | Out-Null
                            $tcpUp = $tc.Connected
                        }
                        $tc.Close()
                    }
                    catch { }
                }
                if (-not $tcpUp) { Start-Sleep -Seconds 10 }
            }
            if (-not $tcpUp) {
                Write-Log "[Linux DNS] $($vm.vmName): SSH still unreachable after restart. Skipping DNS flip." -Warning
                $allOk = $false
                # Still attempt DNS registration from the DC side (A record)
                # even though we can't configure the VM itself.
                $vmIpFallback = Get-LinuxVmIPAddress -VmName $vm.vmName
                if ($vmIpFallback) {
                    $null = Register-LinuxVmDns -VmName $vm.vmName -Domain $domain -DCName $dcVm.vmName -IPAddress $vmIpFallback
                }
                continue
            }
            Write-Log "[Linux DNS] $($vm.vmName): SSH recovered after restart ($vmIpPre)" -LogOnly
        }
        # --- End SSH readiness gate ---------------------------------------

        # Invoke-LinuxVmCommand has its own 3-attempt SSH retry (10s/20s
        # backoff), but during Phase 2 the Linux VM may simply not have
        # sshd up yet.  Wrap with an outer retry so we keep trying longer.
        $dnsOk = $false
        $maxDnsRetries = 3
        for ($dnsAttempt = 1; $dnsAttempt -le $maxDnsRetries; $dnsAttempt++) {
            # On non-final outer attempts, suppress the inner "failed" log
            # so a recoverable SSH timeout doesn't show as an ERROR.
            # The outer loop logs its own warning instead.
            $isLastOuter = ($dnsAttempt -eq $maxDnsRetries)
            $res = Invoke-LinuxVmCommand -VmName $vm.vmName -BashCommand $cmd -Sudo `
                -DisplayName "memlabs-set-dns $dcIp $domain" -TimeoutSeconds 60 `
                -SuppressLog:(-not $isLastOuter)
            if (-not $res.ScriptBlockFailed -and $res.CommandResult) {
                Write-Log "[Linux DNS] $($vm.vmName): now using DC DNS ($dcIp). $($res.ScriptBlockOutput)" -Success
                $dnsOk = $true
                break
            }
            # Only retry on SSH transport failures (exit 255). If the remote
            # command itself failed, retrying won't help.
            if ($res.ExitCode -ne 255) {
                break
            }
            if ($dnsAttempt -lt $maxDnsRetries) {
                $delay = 30 * $dnsAttempt
                Write-Log "[Linux DNS] $($vm.vmName): SSH unreachable (outer attempt $dnsAttempt/$maxDnsRetries). Waiting ${delay}s..." -Warning
                Start-Sleep -Seconds $delay
            }
        }
        if (-not $dnsOk) {
            Write-Log "[Linux DNS] $($vm.vmName): failed to flip to DC DNS. $($res.ScriptBlockOutput)" -Warning
            $allOk = $false
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

            # Update LastKnownIP in VM Notes if the IP differs from what
            # was recorded in Phase 1 (shouldn't happen now that all Linux
            # VMs boot with static IPs, but keep as a safety net).
            $vmNote = Get-VMNote -vmName $vm.vmName
            $oldIp = if ($vmNote) { $vmNote.LastKnownIP } else { $null }
            if ($oldIp -ne $vmIp) {
                if ($oldIp) {
                    Write-Log "[Linux DNS] $($vm.vmName): IP changed $oldIp -> $vmIp — updating LastKnownIP" -Verbose
                }
                Set-VMNote -vmName $vm.vmName -vmNote ([pscustomobject]@{ LastKnownIP = $vmIp })
            }
            # DHCP reservation was already created by New-LinuxVirtualMachine
            # in Phase 1 using the pre-assigned IP.
        }
        else {
            Write-Log "[Linux DNS] $($vm.vmName): could not resolve IPv4; skipping DNS A record registration" -Warning
        }
    }
    return $allOk
}


function Restart-LinuxVmAndWait {
    <#
    .SYNOPSIS
        Reboot a Linux VM and wait until it's SSH-reachable again.

    .DESCRIPTION
        Before rebooting, checks via SSH whether a reboot is actually
        warranted (pending reboot flag, broken dpkg state). If SSH is
        functional and no reboot is pending, skips the reboot and returns
        the current IP so the caller can simply retry the command.

        When a reboot IS needed, issues 'sudo reboot' over SSH (or
        Stop-VM/Start-VM as fallback), sleeps briefly for the VM to begin
        shutting down, then calls Wait-LinuxVmReady to wait for SSH.
        Returns the new IP on success or $null on failure.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $false)][string]$IPAddress,
        [Parameter(Mandatory = $false)][string]$ExpectedIPAddress,
        [Parameter(Mandatory = $false)][int]$WaitTimeoutSeconds = 900
    )

    # ── Guard: if SSH is functional, check whether a reboot is actually needed.
    # Transient failures (apt lock, slow service start) don't require a reboot,
    # and on a busy host the reboot itself is risky (VM may not come back for
    # minutes). Only reboot when the OS actually flags one as pending.
    if ($IPAddress) {
        $rebootCheckBash = @'
NEEDS=0
REASONS=""
# Ubuntu/Debian: file created by apt/dpkg when a reboot is needed (kernel update, etc.)
if [ -f /var/run/reboot-required ]; then
    NEEDS=1
    REASONS="${REASONS} reboot-required"
    echo "reboot-required packages:"
    cat /var/run/reboot-required.pkgs 2>/dev/null | head -10 || echo "(none listed)"
fi
# dpkg in broken state (interrupted install, half-configured, etc.)
if dpkg --audit 2>/dev/null | grep -q .; then
    NEEDS=1
    REASONS="${REASONS} dpkg-broken"
    echo "dpkg audit:"
    dpkg --audit 2>/dev/null | head -10
fi
# cloud-init still running — rebooting would interrupt first-boot setup
if command -v cloud-init >/dev/null 2>&1; then
    CI_STATUS=$(cloud-init status 2>/dev/null || echo "unknown")
    echo "cloud-init: $CI_STATUS"
    if echo "$CI_STATUS" | grep -q "running"; then
        echo "CLOUD_INIT_ACTIVE"
        exit 0
    fi
fi
if [ "$NEEDS" = "1" ]; then
    echo "REBOOT_NEEDED:${REASONS}"
else
    echo "NO_REBOOT_NEEDED"
fi
'@
        $rebootCheck = Invoke-LinuxVmCommand -VmName $VmName -IPAddress $IPAddress `
            -Sudo -TimeoutSeconds 20 -SuppressLog -BashCommand $rebootCheckBash `
            -DisplayName "reboot-check"

        if ($rebootCheck -and -not $rebootCheck.ScriptBlockFailed -and $rebootCheck.ExitCode -eq 0) {
            $checkOutput = $rebootCheck.ScriptBlockOutput
            if ($checkOutput -match 'CLOUD_INIT_ACTIVE') {
                Write-Log "$VmName`: cloud-init still running; skipping reboot to avoid interrupting first-boot setup" -Warning
                return $IPAddress
            }
            elseif ($checkOutput -match 'NO_REBOOT_NEEDED') {
                Write-Log "$VmName`: SSH functional and no reboot pending; skipping reboot (caller should retry)" -Warning
                return $IPAddress
            }
            elseif ($checkOutput -match 'REBOOT_NEEDED:(.+)') {
                $reasons = $Matches[1].Trim()
                Write-Log "$VmName`: Reboot warranted ($reasons); proceeding with reboot" -LogOnly
                foreach ($line in ($checkOutput -split "`n")) {
                    Write-Log "$VmName`:   reboot-check> $line" -LogOnly
                }
            }
        }
        else {
            Write-Log "$VmName`: SSH reboot-check failed (exit=$($rebootCheck.ExitCode)); proceeding with reboot" -LogOnly
        }
    }

    Write-Log "$VmName`: Rebooting VM for retry..."
    # Try graceful SSH reboot first; if SSH is broken, fall back to Hyper-V.
    # 'sync' first so any freshly-written dpkg status DB is flushed to disk
    # before the reboot — a non-graceful reboot on a busy host can otherwise
    # truncate /var/lib/dpkg/status (ext4 delayed allocation).
    if ($IPAddress) {
        $null = Invoke-LinuxVmCommand -VmName $VmName -IPAddress $IPAddress `
            -BashCommand 'sync; nohup bash -c "sleep 2 && sync && reboot" &>/dev/null &' `
            -Sudo -TimeoutSeconds 10 -SuppressLog
    }
    Start-Sleep -Seconds 10

    # Helper: wait for the VM to leave any transitional state (Stopping,
    # Starting, Saving, etc.). Returns the final VM object.
    $waitForStable = {
        param([string]$Name, [int]$MaxWaitSec)
        $vmObj = Get-VM -Name $Name -ErrorAction SilentlyContinue
        if ($vmObj -and $vmObj.State -notin @('Running', 'Off')) {
            Write-Log "$Name`: VM in '$($vmObj.State)' state; waiting up to ${MaxWaitSec}s for stable state" -LogOnly
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($sw.Elapsed.TotalSeconds -lt $MaxWaitSec) {
                Start-Sleep -Seconds 3
                $vmObj = Get-VM -Name $Name -ErrorAction SilentlyContinue
                if (-not $vmObj -or $vmObj.State -in @('Running', 'Off')) { break }
            }
            $sw.Stop()
            if ($vmObj -and $vmObj.State -notin @('Running', 'Off')) {
                Write-Log "$Name`: VM still in '$($vmObj.State)' after ${MaxWaitSec}s" -Warning
            }
        }
        return $vmObj
    }

    $vm = & $waitForStable $VmName 60

    # If the VM is still running after the SSH reboot attempt, force via Hyper-V.
    # Retry once if the first attempt fails (common when the VM is mid-transition).
    $maxAttempts = 2
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        if ($vm -and $vm.State -eq 'Running') {
            try {
                Stop-VM -Name $VmName -Force -ErrorAction Stop
                Start-Sleep -Seconds 3
                Start-VM -Name $VmName -ErrorAction Stop
                Write-Log "$VmName`: Hyper-V reboot succeeded (attempt $attempt)" -LogOnly
                break
            }
            catch {
                Write-Log "$VmName`: Hyper-V reboot failed (attempt $attempt/$maxAttempts): $_" -Warning
                if ($attempt -lt $maxAttempts) {
                    # Re-wait for stable state before retrying
                    $vm = & $waitForStable $VmName 90
                }
            }
        }
        elseif ($vm -and $vm.State -eq 'Off') {
            try {
                Start-VM -Name $VmName -ErrorAction Stop
                Write-Log "$VmName`: Start-VM succeeded (was Off)" -LogOnly
                break
            }
            catch {
                Write-Log "$VmName`: Start-VM failed (attempt $attempt/$maxAttempts): $_" -Warning
                if ($attempt -lt $maxAttempts) {
                    Start-Sleep -Seconds 10
                    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
                }
            }
        }
        else {
            # VM in unexpected state or missing — wait and re-check
            if ($attempt -lt $maxAttempts) {
                $vm = & $waitForStable $VmName 90
            }
            else {
                Write-Log "$VmName`: VM in unexpected state '$($vm.State)' after $maxAttempts attempts" -Warning
                # Last resort: TurnOff is instantaneous and works in any state
                try {
                    Stop-VM -Name $VmName -TurnOff -Force -ErrorAction Stop
                    Start-Sleep -Seconds 3
                    Start-VM -Name $VmName -ErrorAction Stop
                    Write-Log "$VmName`: TurnOff + Start-VM succeeded as last resort" -LogOnly
                }
                catch {
                    Write-Log "$VmName`: Last-resort TurnOff + Start failed: $_" -Warning
                }
            }
        }
    }

    $newIp = Wait-LinuxVmReady -VmName $VmName -TimeoutSeconds $WaitTimeoutSeconds -ExpectedIPAddress $ExpectedIPAddress
    if ($newIp) {
        Write-Log "$VmName`: VM back online at $newIp after reboot" -Success
    }
    else {
        Write-Log "$VmName`: VM did not come back after reboot within ${WaitTimeoutSeconds}s" -Failure
    }
    return $newIp
}


function Write-LinuxHostStorageDiag {
    <#
    .SYNOPSIS
        Log HOST-side storage state for a VM (free space on the volume backing
        its VHDXs, disk sizes, and recent host disk/storage errors).

    .DESCRIPTION
        A zeroed guest file that keeps its size (e.g. /var/lib/dpkg/status full
        of NUL) with a KNOWN-GOOD base image points at the host failing to
        persist writes -- typically the volume backing the VM's dynamic VHDX
        running out of space, or a disk/storvsp fault. This captures that
        signal into the log at failure time. Purely diagnostic; never throws.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [string]$Context = ""
    )
    try {
        $lines = New-Object System.Collections.Generic.List[string]
        $qualifiers = @{}
        $disks = Get-VMHardDiskDrive -VMName $VmName -ErrorAction SilentlyContinue
        foreach ($d in $disks) {
            if ($d.Path) {
                $sz = if (Test-Path $d.Path) { "$([math]::Round((Get-Item $d.Path).Length / 1GB, 2))GB" } else { "missing" }
                $lines.Add("  vhdx: $($d.Path) ($sz)")
                $q = (Split-Path $d.Path -Qualifier)
                if ($q) { $qualifiers[$q] = $true }
            }
        }
        foreach ($q in $qualifiers.Keys) {
            $vol = Get-Volume -DriveLetter ($q.TrimEnd(':')) -ErrorAction SilentlyContinue
            if ($vol) {
                $freeGB = [math]::Round($vol.SizeRemaining / 1GB, 2)
                $totGB = [math]::Round($vol.Size / 1GB, 2)
                $pctFree = if ($vol.Size) { [math]::Round(100 * $vol.SizeRemaining / $vol.Size, 1) } else { 0 }
                $lines.Add("  volume ${q} free=${freeGB}GB / ${totGB}GB (${pctFree}% free)")
            }
        }
        # Recent host storage faults (disk/NTFS/VHD/storvsp) — the smoking gun
        # for silent write loss into a guest VHDX.
        try {
            $since = (Get-Date).AddHours(-2)
            $evts = Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $since; Level = 1, 2, 3 } -ErrorAction SilentlyContinue |
                Where-Object { $_.ProviderName -match 'disk|Ntfs|vhdmp|storvsp|volmgr|volsnap|Vhd' } | Select-Object -First 8
            foreach ($e in $evts) {
                $firstLine = (($e.Message -split "`n") | Select-Object -First 1).Trim()
                $lines.Add("  evt [$($e.ProviderName)/$($e.Id)] $($e.TimeCreated): $firstLine")
            }
        }
        catch {}
        if ($lines.Count -eq 0) { $lines.Add("  (no host storage info available)") }
        Write-Log "[HostStorageDiag] $VmName $Context`n$($lines -join "`n")" -LogOnly
    }
    catch {
        Write-Log "[HostStorageDiag] $VmName`: diag failed: $_" -LogOnly
    }
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
    $vmCount = @($deployConfig.virtualMachines).Count
    $waitTimeout = Get-LinuxVmWaitTimeout -VmObject $ProxyVM -VmCount $vmCount
    $ip = Wait-LinuxVmReady -VmName $vmName -TimeoutSeconds $waitTimeout -ExpectedIPAddress $expectedIp
    if (-not $ip) {
        Write-Log "[Proxy] $vmName`: VM not reachable over SSH; cannot install Squid" -Failure
        return $false
    }

    # ── Network validation ──
    # The proxy VM needs outbound internet access for apt.  DNS and HTTP
    # must work before we attempt the install, otherwise apt hangs for
    # minutes/hours with no useful output.  Retry with backoff to allow
    # time for NAT/routing to come up on the host.
    $netCheckBash = @'
DNS_OK=0; HTTP_OK=0
if getent hosts archive.ubuntu.com >/dev/null 2>&1; then DNS_OK=1; fi
if [ "$DNS_OK" = "1" ]; then
    if curl --connect-timeout 10 -sI http://archive.ubuntu.com/ubuntu/dists/ 2>/dev/null | head -1 | grep -q "200\|301\|302"; then
        HTTP_OK=1
    fi
fi
echo "DNS=$DNS_OK HTTP=$HTTP_OK"
'@
    $netOk = $false
    for ($netAttempt = 1; $netAttempt -le 6; $netAttempt++) {
        write-progress2 "Proxy Setup" -Status "$vmName`: verifying internet access (attempt $netAttempt/6)..." -force
        $netResult = Invoke-LinuxVmCommand -VmName $vmName -IPAddress $ip -BashCommand $netCheckBash `
            -Sudo -TimeoutSeconds 30 -SuppressLog -DisplayName "Network check"
        if ($netResult -and -not $netResult.ScriptBlockFailed -and $netResult.ScriptBlockOutput -match 'DNS=1 HTTP=1') {
            $netOk = $true
            Write-Log "[Proxy] $vmName`: Network OK (DNS + HTTP verified)" -LogOnly
            break
        }
        $status = if ($netResult.ScriptBlockOutput -match 'DNS=(\d) HTTP=(\d)') { "DNS=$($Matches[1]) HTTP=$($Matches[2])" } else { "unreachable" }
        Write-Log "[Proxy] $vmName`: Network check $netAttempt/6 failed ($status); retrying in 30s..." -Warning
        Start-Sleep -Seconds 30
    }
    if (-not $netOk) {
        # Collect diagnostics before failing
        $diagBash = 'echo "=== resolv.conf ==="; cat /etc/resolv.conf; echo "=== ip route ==="; ip route show; echo "=== resolvectl ==="; resolvectl status 2>/dev/null | head -20'
        $diag = Invoke-LinuxVmCommand -VmName $vmName -IPAddress $ip -BashCommand $diagBash -Sudo -TimeoutSeconds 15 -SuppressLog -DisplayName "Network diagnostics"
        $diagText = if ($diag -and $diag.ScriptBlockOutput) { $diag.ScriptBlockOutput } else { "(no output)" }
        Write-Log "[Proxy] $vmName`: No internet access after 6 attempts. apt requires DNS + HTTP to archive.ubuntu.com.`n$diagText" -Failure
        return $false
    }

    $squidConf = @"
# memlabs Squid forward proxy
# Managed by Install-LinuxProxyServer -- changes will be overwritten.

http_port 3128

# Human-readable log format for lab diagnostics.
# Native squid format uses Unix epoch seconds; this uses ISO timestamps
# and reorders fields for quick visual scanning by Windows admins.
#   TIME  CLIENT  RESULT/STATUS  METHOD  URL  RESPONSE_MS  SIZE  MIME
logformat memlabs %{%Y-%m-%d %H:%M:%S}tl %>a %Ss/%03>Hs %rm %ru %6tr %<st %mt
access_log daemon:/var/log/squid/access.log memlabs

# Blocklist: managed via the Proxy Admin web UI (port 8443).
# Squid reads this file on start and on 'squid -k reconfigure'.
acl blocklist dstdomain "/etc/squid/blocklist.txt"
http_access deny blocklist

# Lab proxy: allow all traffic.  Squid's role here is outbound NAT
# control via Hyper-V port ACLs, not access restriction.
http_access allow all

# Disable disk cache; lab proxy is for outbound NAT control, not perf.
cache deny all

# Keep memory cache small (default 256MB is excessive for 1GB VM).
cache_mem 64 MB

# Honour client UA / forwarded-for for diagnostics; this is a lab.
forwarded_for on
via off

coredump_dir /var/spool/squid
"@

    # Base64-encode the config so we can pipe it through bash without
    # quoting hell.
    $confBytes = [System.Text.Encoding]::UTF8.GetBytes($squidConf)
    $confB64 = [Convert]::ToBase64String($confBytes)

    $bash = Get-LinuxScript -Name 'proxy/install-squid' -Variables @{ CONF_B64 = $confB64 } -IncludeAptRetry

    write-progress2 "Proxy Setup" -Status "$vmName`: installing Squid proxy (apt update + packages; this can take several minutes)..." -force
    $result = Invoke-LinuxVmCommand -VmName $vmName -IPAddress $ip -BashCommand $bash -Sudo -TimeoutSeconds 900 -DisplayName "Install Squid"

    # ── Resilient retry logic ──
    # Separate "script ran fine but squid slow to start" (exit=0, no PROXY_READY)
    # from actual failures (exit!=0 or ScriptBlockFailed). The former just needs
    # more time; the latter needs a full reboot.
    if ($result.ScriptBlockFailed -or $result.ExitCode -ne 0 -or $result.ScriptBlockOutput -notmatch 'PROXY_READY') {
        $tail = $null
        if ($result -and $result.ScriptBlockOutput) {
            $lines = ($result.ScriptBlockOutput -split "`n")
            $tail = ($lines | Select-Object -Last 20) -join "`n"
        }
        Write-Log "[Proxy] $vmName`: First attempt failed (exit=$($result.ExitCode), ScriptBlockFailed=$($result.ScriptBlockFailed)). Output tail:`n$tail" -Warning

        $needsReboot = $true

        # If the install itself succeeded (exit=0) but squid just didn't start
        # listening in time, try a lightweight self-test before rebooting.
        # On a busy host squid may simply need more time to initialize.
        if (-not $result.ScriptBlockFailed -and $result.ExitCode -eq 0) {
            Write-Log "[Proxy] $vmName`: Install exited 0; checking if squid just needs more time..." -Warning
            $selfTest = Invoke-LinuxVmCommand -VmName $vmName -IPAddress $ip -Sudo -TimeoutSeconds 90 `
                -BashCommand 'for i in $(seq 1 60); do if ss -ltn "sport = :3128" 2>/dev/null | grep -q ":3128"; then echo "PROXY_READY"; exit 0; fi; sleep 1; done; echo "squid still not listening"; systemctl --no-pager status squid 2>&1 | head -15; exit 1' `
                -DisplayName "Squid self-test (extended)"
            if ($selfTest -and -not $selfTest.ScriptBlockFailed -and $selfTest.ExitCode -eq 0 -and $selfTest.ScriptBlockOutput -match 'PROXY_READY') {
                Write-Log "[Proxy] $vmName`: Squid came up on extended self-test (no reboot needed)" -Success
                $result = $selfTest
                $needsReboot = $false
            }
            else {
                Write-Log "[Proxy] $vmName`: Extended self-test still negative; will reboot." -Warning
            }
        }

        if ($needsReboot) {
            # If the first attempt timed out, the SSH channel was severed but
            # the remote apt-get/dpkg process keeps running and holds the lock.
            # Kill orphaned apt/dpkg processes before retrying so
            # wait_for_apt_lock doesn't spin for 300s and fail.
            $wasTimeout = $result.ScriptBlockFailed -and $result.ScriptBlockOutput -match 'TIMEOUT'
            if ($wasTimeout) {
                Write-Log "[Proxy] $vmName`: First attempt timed out; killing orphaned apt/dpkg processes..." -Warning
                $killBash = @'
# Kill any orphaned processes left from the timed-out SSH session.
# The SSH timeout kills the local ssh.exe but the remote bash -s
# (and its children) keep running.  Kill them all.
for proc in apt-get dpkg apt squid; do
    pkill -9 -x "$proc" 2>/dev/null && echo "killed $proc" || true
done
# Kill orphaned bash scripts that look like our install payloads.
# Match on the 'bash -s' processes spawned by SSH (PPID=1 after
# the SSH channel dies and they get reparented to init).
for pid in $(pgrep -x bash); do
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ "$ppid" = "1" ]; then
        echo "killed orphaned bash PID=$pid"
        kill -9 "$pid" 2>/dev/null || true
    fi
done
# Release stale lock files
rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null || true
# Recover interrupted dpkg state
dpkg --configure -a 2>/dev/null || true
echo "APT_CLEANUP_DONE"
'@
                $cleanup = Invoke-LinuxVmCommand -VmName $vmName -IPAddress $ip -BashCommand $killBash `
                    -Sudo -TimeoutSeconds 60 -DisplayName "Kill orphaned apt processes"
                if ($cleanup -and $cleanup.ScriptBlockOutput -match 'APT_CLEANUP_DONE') {
                    Write-Log "[Proxy] $vmName`: Orphaned processes cleaned up; retrying without reboot" -LogOnly
                }
                else {
                    Write-Log "[Proxy] $vmName`: Cleanup inconclusive; falling back to reboot" -Warning
                    $wasTimeout = $false
                }
            }

            if (-not $wasTimeout) {
                Write-Log "[Proxy] $vmName`: Rebooting and retrying..." -Warning
                $expectedIp = Get-LinuxVmExpectedStaticIP -VmObject $ProxyVM -DeployConfig $deployConfig
                $ip = Restart-LinuxVmAndWait -VmName $vmName -IPAddress $ip -ExpectedIPAddress $expectedIp -WaitTimeoutSeconds 900
                if (-not $ip) {
                    Write-Log "[Proxy] $vmName`: VM not reachable after reboot; aborting." -Failure
                    return $false
                }
            }

            write-progress2 "Proxy Setup" -Status "$vmName`: retrying Squid install (this can take several minutes)..." -force
            $result = Invoke-LinuxVmCommand -VmName $vmName -IPAddress $ip -BashCommand $bash -Sudo -TimeoutSeconds 900 -DisplayName "Install Squid (retry)"
        }
    }

    if ($result.ScriptBlockFailed -or $result.ExitCode -ne 0) {
        Write-Log "[Proxy] $vmName`: Squid install failed (ExitCode=$($result.ExitCode))`n$($result.ScriptBlockOutput)" -Failure
        Write-LinuxHostStorageDiag -VmName $vmName -Context "(after Squid install failed)"
        return $false
    }
    if ($result.ScriptBlockOutput -notmatch 'PROXY_READY') {
        Write-Log "[Proxy] $vmName`: Squid install did not report ready`n$($result.ScriptBlockOutput)" -Failure
        Write-LinuxHostStorageDiag -VmName $vmName -Context "(Squid not ready)"
        return $false
    }

    Write-Log "[Proxy] $vmName`: Squid listening on ${ip}:3128 (outbound access enforced by Hyper-V port ACLs)"

    # ---- Proxy Admin web UI ----
    # A lightweight Flask app that manages /etc/squid/blocklist.txt and
    # reloads Squid on changes. Runs as a systemd service on port 8443.
    # The .py and .service files live under scripts/linux/proxy/.
    $proxyAdminApp = Get-Content -Path (Join-Path $script:LinuxScriptDir 'proxy\proxy-admin.py') -Raw
    $proxyAdminService = Get-Content -Path (Join-Path $script:LinuxScriptDir 'proxy\proxy-admin.service') -Raw

    $appB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($proxyAdminApp))
    $svcB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($proxyAdminService))

    $webUiBash = Get-LinuxScript -Name 'proxy/deploy-webui' -Variables @{ APP_B64 = $appB64; SVC_B64 = $svcB64 }

    write-progress2 "Proxy Setup" -Status "$vmName`: Squid ready; installing Proxy Admin web UI..." -force
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

    # ---- MOTD + squidlog helper ----
    # Install a colorized squid log viewer and a login banner that
    # advertises it so SSH sessions land with useful instructions.
    $proxyFqdn = "$vmName.$($deployConfig.vmOptions.domainName)"
    $squidlogContent = Get-Content -Path (Join-Path $script:LinuxScriptDir 'proxy\squidlog') -Raw
    $squidlogB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($squidlogContent))

    $motdBash = Get-LinuxScript -Name 'proxy/install-motd' -Variables @{ SQUIDLOG_B64 = $squidlogB64; PROXY_FQDN = $proxyFqdn }
    $result3 = Invoke-LinuxVmCommand -VmName $vmName -IPAddress $ip -BashCommand $motdBash -Sudo -TimeoutSeconds 30 -DisplayName "Install MOTD + squidlog"
    if ($result3.ScriptBlockFailed -or $result3.ExitCode -ne 0) {
        Write-Log "[Proxy] $vmName`: MOTD install failed (ExitCode=$($result3.ExitCode))`n$($result3.ScriptBlockOutput)" -Warning
    }
    elseif ($result3.ScriptBlockOutput -notmatch 'MOTD_READY') {
        Write-Log "[Proxy] $vmName`: MOTD install did not report ready`n$($result3.ScriptBlockOutput)" -Warning
    }
    else {
        Write-Log "[Proxy] $vmName`: MOTD + squidlog helper installed"
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

function Get-LinuxXrdpPackagesBashScript {
    <#
    .SYNOPSIS
        Bash body that installs xrdp + xfce4 desktop packages.
    #>
    [CmdletBinding()]
    param ()

    return (Get-LinuxScript -Name 'roles/xrdp-packages' -IncludeAptRetry)
}

function Get-LinuxXrdpConfigBashScript {
    <#
    .SYNOPSIS
        Bash body that configures xrdp sessions, xfce4 panel defaults,
        disables screen lock/screensaver, and enables xrdp + firewall.
    #>
    [CmdletBinding()]
    param ()

    return (Get-LinuxScript -Name 'roles/xrdp-config')
}

function Get-LinuxFirefoxBashScript {
    <#
    .SYNOPSIS
        Bash body that installs Firefox from Mozilla's deb repo (not the
        Ubuntu snap shim) and wires it as the system default browser.
    #>
    [CmdletBinding()]
    param ()

    return (Get-LinuxScript -Name 'roles/firefox' -IncludeAptRetry)
}

function Get-LinuxClientBashScript {
    <#
    .SYNOPSIS
        Bash body that configures per-user GNOME settings for LinuxClient VMs:
        .xsession for xrdp and per-user dconf fixups. Idempotent.

    .DESCRIPTION
        LinuxClient VMs use the UbuntuDesktop2404.vhdx base which has
        xrdp, GNOME, GDM3, Edge, Intune, dash-to-panel, dconf system
        defaults, and all supporting packages baked in during image build.

        This Phase 3 script handles only per-user configuration:
          1. Creates ~/.xsession + ~/.xsessionrc so xrdp starts a GNOME
             session on X11 (per-user files, can't be baked since
             vmbuildadmin doesn't exist until deploy time)
          2. Patches per-user dconf to replace Firefox with Edge in
             taskbar favorites (safety net for users who logged in before
             the system-wide default was applied)
        Returns: [string] bash source.  Assumes it will be run as root.
    #>
    [CmdletBinding()]
    param ()

    return (Get-LinuxScript -Name 'roles/client-config')
}

function Get-LinuxRealmJoinBashScript {
    <#
    .SYNOPSIS
        Bash body that installs realmd + sssd stack and joins the lab AD.

    .DESCRIPTION
        Reads the shared realm-join.sh script and injects the domain,
        DC IP, admin user, and password as bash variables. Used by both
        Phase 3 SSH dispatch and cloud-init seed.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Domain,
        [Parameter(Mandatory = $true)][string]$DcIp,
        [Parameter(Mandatory = $true)][string]$AdminUser,
        [Parameter(Mandatory = $true)][string]$AdminPassword,
        [Parameter(Mandatory = $false)][string]$DomainUser
    )

    $pwBashSingle = $AdminPassword -replace "'", "'\''"
    $domainLower = $Domain.ToLower()

    $vars = @{
        DOMAIN    = $domainLower
        DC_IP     = $DcIp
        ADMIN_USER = $AdminUser
        ADMIN_PWD  = $pwBashSingle
    }
    # Optional: per-VM domain user granted NOPASSWD sudo on the box (mirrors the
    # Windows domainUser=local-admin model). Omitted -> Domain-Admins-only sudo.
    if ($DomainUser) { $vars['DOMAIN_USER'] = $DomainUser }

    return (Get-LinuxScript -Name 'roles/realm-join' -IncludeAptRetry -IncludeSetDcDns -Variables $vars)
}

function Get-LinuxProxyClientBashScript {
    <#
    .SYNOPSIS
        Bash body that points a Linux VM at the lab Squid proxy (env vars,
        apt proxy, profile.d, snap proxy). Linux analog of Set-WindowsClientProxy.

    .DESCRIPTION
        Builds the http://<host>:<port> proxy URL and a no_proxy list that
        keeps intra-lab traffic direct (localhost, the AD domain suffix, the
        proxy host itself, the VM's own /24, and the DC). Injects them into
        the shared roles/proxy-client.sh script.

    .PARAMETER ProxyHost
        IP (preferred) or FQDN of the Linux Proxy VM running Squid.

    .PARAMETER ProxyPort
        Squid listener port. Defaults to 3128.

    .PARAMETER Domain
        AD domain DNS suffix, added to no_proxy as ".<domain>".

    .PARAMETER BypassNetwork
        Optional /24 network base (e.g. 10.0.1.0). Adds "<base>.0/24" and the
        DC ("<base>.1") to no_proxy so intra-subnet traffic stays direct.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$ProxyHost,
        [Parameter(Mandatory = $false)][int]$ProxyPort = 3128,
        [Parameter(Mandatory = $true)][string]$Domain,
        [Parameter(Mandatory = $false)][string]$BypassNetwork
    )

    $proxyUrl = "http://${ProxyHost}:$ProxyPort"

    $noProxyEntries = @('localhost', '127.0.0.1', '::1', ".$Domain", $ProxyHost)
    if ($BypassNetwork) {
        $base = $BypassNetwork
        if ($base -match '^(\d+\.\d+\.\d+)\.\d+$') { $base = $Matches[1] }
        if ($base -match '^\d+\.\d+\.\d+$') {
            $noProxyEntries += "$base.0/24"
            $noProxyEntries += "$base.1"   # DC (memlabs convention)
        }
    }
    $noProxy = ($noProxyEntries | Where-Object { $_ } | Select-Object -Unique) -join ','

    return (Get-LinuxScript -Name 'roles/proxy-client' -Variables @{ PROXY_URL = $proxyUrl; NO_PROXY = $noProxy })
}

function Invoke-LinuxRoleConfiguration {
    <#
    .SYNOPSIS
        Phase 3 entrypoint for Linux VMs. Applies role-driven post-boot config
        (xrdp/Firefox/realm-join) over SSH so cloud-init can stay minimal.

    .DESCRIPTION
        Decides which bash modules apply based on VM flags:
          - enableRDP=true       -> xrdp packages, xrdp config, Firefox
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

    # Proxy client config MUST run first: it points apt/env at Squid so the
    # later apt-heavy modules (xrdp/gnome/realm-join) succeed once the deny-ACL
    # is stamped (post-Phase-11). No-op for VMs that didn't opt into useProxy.
    if (Test-VmUsesProxy -Vm $Vm -DeployConfig $DeployConfig) {
        $proxyHost = $null
        $proxyVm = $DeployConfig.virtualMachines | Where-Object { $_.role -eq 'Proxy' } | Select-Object -First 1
        if ($proxyVm) {
            $proxyHost = Get-LinuxVmExpectedStaticIP -VmObject $proxyVm -DeployConfig $DeployConfig
            if (-not $proxyHost) { $proxyHost = Get-LinuxVmIPAddress -VmName $proxyVm.vmName }
            if (-not $proxyHost) { $proxyHost = "$($proxyVm.vmName).$($DeployConfig.vmOptions.domainName)" }
        }
        else {
            $existingProxyName = Get-ExistingForDomain -DomainName $DeployConfig.vmOptions.domainName -Role 'Proxy' | Select-Object -First 1
            if ($existingProxyName) {
                $proxyHost = Get-LinuxVmIPAddress -VmName $existingProxyName
                if (-not $proxyHost) { $proxyHost = "$existingProxyName.$($DeployConfig.vmOptions.domainName)" }
            }
        }

        if ($proxyHost) {
            $bypassNet = if ($Vm.network) { $Vm.network } else { $DeployConfig.vmOptions.network }
            $ops.Add([pscustomobject]@{
                Name       = 'proxyClient'
                Label      = "Configuring proxy client ($proxyHost`:3128)"
                Script     = (Get-LinuxProxyClientBashScript -ProxyHost $proxyHost -Domain $DeployConfig.vmOptions.domainName -BypassNetwork $bypassNet)
                TimeoutSec = 120
                Tag        = 'memlabs-proxy-client'
            })
        }
        else {
            Write-Log "[LinuxConfig] $vmName`: useProxy=true but no Proxy VM in config or domain; skipping proxy client config" -Warning
        }
    }

    if ($Vm.PSObject.Properties.Name -contains 'enableRDP' -and [bool]$Vm.enableRDP) {
        $ops.Add([pscustomobject]@{
            Name       = 'xrdpPackages'
            Label      = 'Installing XRDP + xfce4 packages'
            Script     = (Get-LinuxXrdpPackagesBashScript)
            TimeoutSec = 1800
            Tag        = 'memlabs-xrdp-packages'
        })
        $ops.Add([pscustomobject]@{
            Name       = 'xrdpConfig'
            Label      = 'Configuring XRDP + xfce4 desktop'
            Script     = (Get-LinuxXrdpConfigBashScript)
            TimeoutSec = 300
            Tag        = 'memlabs-xrdp-config'
        })
        $ops.Add([pscustomobject]@{
            Name       = 'firefox'
            Label      = 'Installing Firefox (Mozilla deb)'
            Script     = (Get-LinuxFirefoxBashScript)
            TimeoutSec = 600
            Tag        = 'memlabs-firefox'
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
            # Per-VM domain user (already prefix-normalized at config load) gets
            # NOPASSWD sudo on the box and becomes the default SSH/RDP login,
            # mirroring the Windows client domainUser=local-admin model.
            $domainUser = $null
            if ($Vm.PSObject.Properties.Name -contains 'domainUser') { $domainUser = $Vm.domainUser }
            $ops.Add([pscustomobject]@{
                Name       = 'joinDomain'
                Label      = "Joining AD domain $domain"
                Script     = (Get-LinuxRealmJoinBashScript -Domain $domain -DcIp $dcIp -AdminUser $adminUser -AdminPassword $adminPwd -DomainUser $domainUser)
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
    $vmCount = @($DeployConfig.virtualMachines).Count
    $waitTimeout = Get-LinuxVmWaitTimeout -VmObject $Vm -VmCount $vmCount
    $ip = Wait-LinuxVmReady -VmName $vmName -TimeoutSeconds $waitTimeout -ExpectedIPAddress $expectedIp
    if (-not $ip) {
        Write-Log "[LinuxConfig] $vmName`: VM not SSH-reachable; cannot apply config." -Failure
        return $false
    }

    # Wait for cloud-init to finish before applying any configuration.
    # Quick non-blocking probe first: if cloud-init already finished (rerun,
    # or Server image with no cloud-init), skip the wait entirely.
    Write-Progress2 -Activity $activity -Status "Checking cloud-init status" -force
    $ciProbe = Invoke-LinuxVmCommand -VmName $vmName -IPAddress $ip `
        -BashCommand 'cloud-init status 2>/dev/null || echo "status: disabled"' `
        -Sudo -DisplayName 'cloud-init-probe' -TimeoutSeconds 30
    $ciStatus = ''
    if ($ciProbe -and $ciProbe.ScriptBlockOutput) {
        if ($ciProbe.ScriptBlockOutput -match 'status:\s*(\S+)') { $ciStatus = $Matches[1] }
    }

    if ($ciStatus -in @('done', 'disabled')) {
        Write-Log "[LinuxConfig] $vmName`: cloud-init already finished (status: $ciStatus). Skipping wait."
    }
    else {
        # cloud-init is still running (first boot). Poll status + last log
        # line so the progress row shows what cloud-init is actually doing
        # (similar to how CM DSC shows ConfigMgr log tails).
        Write-Log "[LinuxConfig] $vmName`: cloud-init status '$ciStatus'; polling until done (reboot expected after)"
        $ciStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $ciTimeoutSec = 600
        $ciDone = $false
        while ($ciStopwatch.Elapsed.TotalSeconds -lt $ciTimeoutSec) {
            # Single SSH call: get status + last useful log line in one round-trip.
            $ciPoll = Invoke-LinuxVmCommand -VmName $vmName -IPAddress $ip `
                -BashCommand '{ cloud-init status 2>/dev/null || echo "status: unknown"; } && echo "---LOGTAIL---" && tail -n 5 /var/log/cloud-init.log 2>/dev/null | grep -v "^$" | tail -n 1' `
                -Sudo -DisplayName 'cloud-init-poll' -TimeoutSeconds 30

            if (-not ($ciPoll -and $ciPoll.CommandResult)) {
                # SSH failed — VM is likely rebooting (cloud-init final reboot).
                Write-Log "[LinuxConfig] $vmName`: SSH lost during cloud-init poll (likely rebooting)"
                Write-Progress2 -Activity $activity -Status "Waiting for post-cloud-init reboot" -force
                Start-Sleep -Seconds 15
                $ip = Wait-LinuxVmReady -VmName $vmName -TimeoutSeconds $waitTimeout -ExpectedIPAddress $expectedIp
                if (-not $ip) {
                    Write-Log "[LinuxConfig] $vmName`: VM not SSH-reachable after cloud-init reboot." -Failure
                    return $false
                }
                Write-Log "[LinuxConfig] $vmName`: SSH ready after cloud-init reboot at $ip"
                $ciDone = $true
                break
            }

            # Parse status and log tail from combined output.
            $pollOutput = $ciPoll.ScriptBlockOutput
            $pollStatus = ''
            $pollLogLine = ''
            if ($pollOutput -match 'status:\s*(\S+)') { $pollStatus = $Matches[1] }
            if ($pollOutput -match '---LOGTAIL---\s*(.+)') {
                $pollLogLine = $Matches[1].Trim()
                # Strip timestamp prefix (e.g. "2026-05-30 12:34:56,789 - ") for cleaner display.
                $pollLogLine = $pollLogLine -replace '^\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2},\d+\s+-\s+', ''
                # Truncate long lines for the progress bar.
                if ($pollLogLine.Length -gt 120) { $pollLogLine = $pollLogLine.Substring(0, 117) + '...' }
            }

            if ($pollStatus -in @('done', 'error', 'disabled')) {
                Write-Log "[LinuxConfig] $vmName`: cloud-init finished (status: $pollStatus)"
                $ciDone = $true
                break
            }

            $elapsed = $ciStopwatch.Elapsed.ToString('mm\:ss')
            $statusMsg = "cloud-init [$elapsed]: $pollLogLine"
            Write-Progress2 -Activity $activity -Status $statusMsg -force

            Start-Sleep -Seconds 5
        }

        if (-not $ciDone) {
            Write-Log "[LinuxConfig] $vmName`: cloud-init poll timed out after ${ciTimeoutSec}s" -Warning

            # Dump diagnostic state before killing anything so we have a
            # full post-mortem in the deploy log.
            $ciDiag = Invoke-LinuxVmCommand -VmName $vmName -IPAddress $ip -Sudo `
                -BashCommand @'
echo "=== PROCESS TREE ==="
pstree -palT $(pgrep -f "/var/lib/cloud/instance/scripts/runcmd" 2>/dev/null) 2>/dev/null || echo "(runcmd PID not found)"
echo "=== CLOUD-INIT STATUS ==="
cloud-init status --long 2>/dev/null || echo "status: unknown"
echo "=== CLOUD-INIT LOG (last 40 lines) ==="
tail -40 /var/log/cloud-init.log 2>/dev/null
echo "=== CLOUD-INIT OUTPUT (last 40 lines) ==="
tail -40 /var/log/cloud-init-output.log 2>/dev/null
echo "=== FAILED SYSTEMD UNITS ==="
systemctl --no-pager --failed 2>/dev/null
echo "=== APT/DPKG LOCKS ==="
fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock 2>&1 || echo "no locks"
'@ `
                -DisplayName 'cloud-init-diag' -TimeoutSeconds 30
            if ($ciDiag -and $ciDiag.ScriptBlockOutput) {
                foreach ($diagLine in ($ciDiag.ScriptBlockOutput -split "`n")) {
                    Write-Log "[LinuxConfig] $vmName`: ci-diag> $diagLine" -LogOnly
                }
            }

            # Kill the stuck cloud-init process tree and neutralize the
            # power_state reboot so the VM doesn't surprise-restart later.
            Write-Log "[LinuxConfig] $vmName`: killing stuck cloud-init and cancelling pending reboot" -Warning
            $ciKill = Invoke-LinuxVmCommand -VmName $vmName -IPAddress $ip -Sudo `
                -BashCommand 'pkill -9 -f "/var/lib/cloud/instance/scripts/runcmd" 2>/dev/null; pkill -9 -f "cloud-init modules" 2>/dev/null; shutdown -c 2>/dev/null; cloud-init status 2>/dev/null || echo "status: killed"' `
                -DisplayName 'cloud-init-kill' -TimeoutSeconds 30
            if ($ciKill -and $ciKill.ScriptBlockOutput) {
                Write-Log "[LinuxConfig] $vmName`: cloud-init cleanup result: $($ciKill.ScriptBlockOutput.Trim())" -LogOnly
            }
        }
    }

    # Run each module as its own SSH invocation so the Phase 3 row reflects
    # exactly what's running. If a module fails, reboot the VM and retry that
    # module once before aborting. A fresh boot clears stale dpkg locks,
    # hung apt processes, and broken service state that commonly cause
    # transient failures.
    $i = 0
    $rebooted = $false
    foreach ($op in $ops) {
        $i++
        $statusText = "[$i/$($ops.Count)] $($op.Label)"
        Write-Progress2 -Activity $activity -Status $statusText -force
        Write-Log "[Phase 3]: $vmName`: $statusText" -LogOnly

        # Wrap in `set -e` so any failed command inside the module aborts the
        # module (and the whole script) with non-zero exit; mirrors the old
        # outer-loop pipefail behavior.
        $script = "#!/bin/bash`nset -euo pipefail`n" + $op.Script + "`n"
        $scriptLf = $script -replace "`r`n", "`n"
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($scriptLf))
        $bash = "echo $b64 | base64 -d > /root/$($op.Tag).sh && chmod 0700 /root/$($op.Tag).sh && /root/$($op.Tag).sh"

        $result = Invoke-LinuxVmCommand -VmName $vmName -IPAddress $ip -BashCommand $bash -Sudo -DisplayName $op.Tag -TimeoutSeconds $op.TimeoutSec
        if (-not ($result -and $result.CommandResult)) {
            # If we haven't rebooted yet, try a reboot-and-retry for this module.
            if (-not $rebooted) {
                $tail = $null
                if ($result -and $result.ScriptBlockOutput) {
                    $lines = ($result.ScriptBlockOutput -split "`n")
                    $tail = ($lines | Select-Object -Last 10) -join "`n"
                }
                Write-Log "[LinuxConfig] $vmName`: module '$($op.Name)' failed (exit=$($result.ExitCode)); rebooting for retry. Tail:`n$tail" -Warning
                $rebooted = $true
                $ip = Restart-LinuxVmAndWait -VmName $vmName -IPAddress $ip -ExpectedIPAddress $expectedIp -WaitTimeoutSeconds 900
                if (-not $ip) {
                    Write-Log "[LinuxConfig] $vmName`: VM not reachable after reboot; aborting." -Failure
                    return $false
                }
                # Retry the same module after reboot.
                Write-Progress2 -Activity $activity -Status "[$i/$($ops.Count)] $($op.Label) (retry after reboot)" -force
                Write-Log "[Phase 3]: $vmName`: [$i/$($ops.Count)] $($op.Label) (retry after reboot)" -LogOnly
                $result = Invoke-LinuxVmCommand -VmName $vmName -IPAddress $ip -BashCommand $bash -Sudo -DisplayName "$($op.Tag)-retry" -TimeoutSeconds $op.TimeoutSec
            }
            if (-not ($result -and $result.CommandResult)) {
                $tail = $null
                if ($result -and $result.ScriptBlockOutput) {
                    $lines = ($result.ScriptBlockOutput -split "`n")
                    $tail = ($lines | Select-Object -Last 20) -join "`n"
                }
            Write-Log "[LinuxConfig] $vmName`: module '$($op.Name)' FAILED (exit=$($result.ExitCode)). Tail:`n$tail" -Failure
            return $false
            }
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

        Returns $false for the Proxy VM itself (it IS the proxy, so it must
        never route through itself) and for the DNS-anchor roles (DC/BDC/
        StandaloneRootCA). Both Windows and Linux VMs can opt in: Windows
        clients are configured via Set-WindowsClientProxy over PSDirect;
        Linux clients via the roles/proxy-client bash module over SSH in
        Phase 3. The $DeployConfig parameter is kept for source
        compatibility with callers but is no longer read.
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
                $ctr = $(if ($old -and $old.Length -ge 4) { [BitConverter]::ToUInt32($old, 0) + 1 } else { 46 })
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
            # ProxySettingsPerUser=0 on the REGULAR IE key (not just the Policies
            # key above) is the switch WinINET actually reads to force machine-
            # wide proxy for every user + SYSTEM. Without it, WinINET stays in
            # per-user mode: the HKLM ProxyServer string is only a template and
            # Windows consumes/blanks it into the per-machine
            # DefaultConnectionSettings blob on the next reboot (seen on
            # ZZ-MOCHI: HKLM IE ProxyServer = '' after a Phase 10 reboot while
            # WinHTTP still pointed at :3128). Setting it here makes the HKLM
            # ProxyServer authoritative and persistent across reboots.
            New-ItemProperty -Path $ieKey -Name 'ProxySettingsPerUser' -PropertyType DWord -Value 0 -Force | Out-Null
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
                $ctr = $(if ($old -and $old.Length -ge 4) { [BitConverter]::ToUInt32($old, 0) + 1 } else { 46 })
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
            # Restore per-user proxy mode (reverse of the machine-wide enforce
            # in Set-WindowsClientProxy) so a de-proxied VM goes back to the
            # Windows default of per-user settings.
            Remove-ItemProperty -Path $ieKey -Name 'ProxySettingsPerUser' -ErrorAction SilentlyContinue
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

    $ok = $true
    foreach ($vm in $clients) {
        # Bypass the proxy for the client's OWN subnet, not the domain default
        # network. A client on a secondary network (e.g. 10.0.2.0) must bypass
        # for 10.0.2.* — using vmOptions.network would bypass the wrong subnet.
        $bypassNet = $vm.network
        if (-not $bypassNet) { $bypassNet = $deployConfig.vmOptions.network }
        Write-Log "[Proxy] Configuring $($vm.vmName) -> $proxyFqdn`:3128"
        $r = Set-WindowsClientProxy -VmName $vm.vmName -Domain $deployConfig.vmOptions.domainName `
                -ProxyFqdn $proxyFqdn -BypassNetwork $bypassNet
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
        Hyper-V integration daemons, desktop environment, Edge, Intune, and
        supporting packages via SSH-driven steps with per-step error checking.

    .DESCRIPTION
        SSH-driven bake: cloud-init creates a temporary user with SSH key,
        then the host SSHes in and drives each installation step sequentially.
        Every step is validated before proceeding. On failure the bake aborts
        with a detailed error and leaves the VM running so you can SSH in to
        diagnose.

        Server variant bakes: HV daemons, qemu-guest-agent, system updates.
        Desktop variant additionally bakes: ubuntu-desktop-minimal, GDM3,
        NetworkManager, xrdp, Microsoft Edge, Intune Portal, dash-to-panel,
        GNOME dconf defaults, and supporting system configuration.

        Re-runnable; stale VMs from interrupted runs are cleaned up on entry.

    .PARAMETER VhdxPath
        Path to the VHDX to modify in place.

    .PARAMETER SwitchName
        Hyper-V switch with outbound internet. Default: 'Default Switch'
        (mapped to MemLabsNAT with static IP 172.16.200.10).

    .PARAMETER TimeoutMinutes
        Wall-clock cap for the entire bake. Hard powers off on timeout.

    .PARAMETER BakeIPAddress
        IP address to SSH into the bake VM. Auto-set to 172.16.200.10 for
        MemLabsNAT. Required for custom switches.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VhdxPath,

        [Parameter(Mandatory = $false)]
        [string]$SwitchName = 'Default Switch',

        [Parameter(Mandatory = $false)]
        [int]$TimeoutMinutes = 20,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Server', 'Desktop')]
        [string]$Variant = 'Server',

        [Parameter(Mandatory = $false)]
        [string]$BakeIPAddress
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
        # with prefix 172.16.200.0/24.  Remove the legacy name so the
        # standard pipeline succeeds.
        $legacyNat = Get-NetNat -Name 'MemLabsNATNat' -ErrorAction SilentlyContinue
        if ($legacyNat) {
            Write-Log "Bake: removing legacy NAT 'MemLabsNATNat' (replaced by '172.16.200.0')." -Warning
            Remove-NetNat -Name 'MemLabsNATNat' -Confirm:$false -ErrorAction SilentlyContinue
        }

        $switchOk = Add-SwitchAndDhcp -NetworkName $SwitchName -NetworkSubnet '172.16.200.0' -DNSServer '8.8.8.8'
        if (-not $switchOk) {
            throw "Bake: failed to create/verify switch + DHCP for '$SwitchName' (172.16.200.0/24)."
        }
        $isMemLabsNAT = $true
        if (-not $BakeIPAddress) { $BakeIPAddress = '172.16.200.10' }
    }
    else {
        # Caller picked a custom switch; just verify it exists.
        $switch = @(Get-VMSwitch -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $SwitchName })
        if ($switch.Count -eq 0) {
            throw "Bake: Hyper-V switch '$SwitchName' not found. Pick a switch with outbound internet (-BakeSwitchName), or use 'MemLabsNAT' to auto-create one. Available: $((Get-VMSwitch | Select-Object -ExpandProperty Name) -join ', ')"
        }
        if ($switch.Count -gt 1) {
            throw "Bake: found $($switch.Count) Hyper-V switches named '$SwitchName'; remove the duplicates and re-run."
        }
        if (-not $BakeIPAddress) {
            throw "Bake: -BakeIPAddress is required when using a custom switch ('$SwitchName'). MemLabsNAT auto-assigns 172.16.200.10."
        }
    }

    # SSH keypair for connecting to the bake VM.  Same ed25519 key used for
    # deployed VMs; the bake user 'memlabs' gets it via cloud-init.
    $keyPair = Get-LinuxAdminSshKeyPair
    $sshPubKey = $keyPair.PublicKey

    # Password for bake console user (vmconnect debugging).
    if (-not $Common -or -not $Common.LocalAdmin) {
        throw "Bake: `$Common.LocalAdmin not available. Run via New-LinuxBaseImage.ps1."
    }
    try { $bakePwd = $Common.LocalAdmin.GetNetworkCredential().Password } catch { $bakePwd = $null }
    if (-not $bakePwd) {
        throw "Bake: could not extract password from `$Common.LocalAdmin."
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
    # DHCP provides the address.
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

    # ── Minimal cloud-init seed ──────────────────────────────────────────
    # Cloud-init ONLY creates the bake user (with SSH key + passwordless
    # sudo) and writes the hv-kvp-daemon.service override.  Everything else
    # (packages, services, config) is driven via SSH from the host so each
    # step gets validated individually with detailed error reporting.
    # On failure the VM is left running for interactive SSH debugging.
    $bakePwdQuoted = "'" + ($bakePwd -replace "'", "''") + "'"

    # hv-kvp-daemon.service override: race-free polling for /dev/vmbus/hv_kvp.
    # The deploy seed ISO writes the same file via its own write_files
    # (idempotent overwrite); having it baked in ensures the very first
    # systemd pass uses the override.
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
        # NetworkManager keyfile config: keep NM running for the GUI, but
        # ignore the lab interface so systemd-networkd's DHCP wins
        # unambiguously on every boot.
        $bakeWriteFilesYaml += "`n"
        $bakeWriteFilesYaml += @'
  - path: /etc/NetworkManager/conf.d/10-memlabs-unmanage-eth.conf
    content: |
      [keyfile]
      unmanaged-devices=interface-name:eth*
'@
    }

    $userData = @"
#cloud-config
hostname: memlabs-bake
preserve_hostname: false

users:
  - name: memlabs
    plain_text_passwd: $bakePwdQuoted
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $sshPubKey

ssh_pwauth: true
$bakeWriteFilesYaml
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
    # Desktop bake pulls ~2GB+ of packages; 4GB RAM avoids OOM during dpkg.
    $bakeMemoryBytes = $(if ($Variant -eq 'Desktop') { 4GB } else { 2GB })
    $bakeProcs = $(if ($Variant -eq 'Desktop') { 4 } else { 2 })
    $vm = New-VM -Name $vmName -Generation 2 -MemoryStartupBytes $bakeMemoryBytes -VHDPath $VhdxPath -SwitchName $SwitchName -ErrorAction Stop
    $bakeSucceeded = $false
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
        Enable-VMResourceMetering -VM $vm -ErrorAction SilentlyContinue

        # ── NIC traffic check ────────────────────────────────────────────
        # Can't rely on KVP for an IP (the daemon is being installed during
        # this bake), but we CAN verify the NIC is sending/receiving traffic.
        # If the interface name doesn't match the network-config, netplan
        # silently ignores the config and the NIC stays completely dark.
        $nicWaitSec = 90
        $nicElapsed = 0
        $nicOk = $false
        while ($nicElapsed -lt $nicWaitSec) {
            Start-Sleep -Seconds 10
            $nicElapsed += 10
            $nic = Get-VMNetworkAdapter -VMName $vmName -ErrorAction SilentlyContinue
            $rxBytes = 0; $txBytes = 0
            if ($nic) {
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
            throw "Bake: VM '$vmName' has zero NIC traffic after ${nicWaitSec}s. The guest interface name may not match the network-config. Check 'ip link' via console: vmconnect localhost $vmName"
        }

        # ── Wait for SSH ─────────────────────────────────────────────────
        Write-Log "Bake: waiting for SSH at $BakeIPAddress (memlabs user)..." -Activity
        $sshDeadline = (Get-Date).AddMinutes(5)
        $sshReady = $false
        while ((Get-Date) -lt $sshDeadline) {
            Start-Sleep -Seconds 5
            # TCP/22 probe
            $tcpOk = $false
            try {
                $tc = [System.Net.Sockets.TcpClient]::new()
                $iar = $tc.BeginConnect($BakeIPAddress, 22, $null, $null)
                if ($iar.AsyncWaitHandle.WaitOne(2000, $false)) {
                    $tc.EndConnect($iar) | Out-Null
                    $tcpOk = $tc.Connected
                }
                $tc.Close()
            } catch { }
            if (-not $tcpOk) { continue }

            # SSH probe
            $probe = Invoke-LinuxVmCommand -VmName $vmName -BashCommand 'echo BAKE_SSH_OK' `
                -IPAddress $BakeIPAddress -UserName 'memlabs' -TimeoutSeconds 15 -SuppressLog
            if ($probe.CommandResult -and $probe.ScriptBlockOutput -match 'BAKE_SSH_OK') {
                $sshReady = $true
                break
            }
        }
        if (-not $sshReady) {
            throw "Bake: SSH not reachable at $BakeIPAddress within 5 minutes. Console: vmconnect localhost $vmName"
        }
        Write-Log "Bake: SSH connected to memlabs@$BakeIPAddress." -Success

        # ── Bake step helper ─────────────────────────────────────────────
        # Runs a bash script via SSH as root (sudo), checks the exit code,
        # and throws with detailed output on failure. Uses a hashtable for
        # the mutable step counter (reference type survives inner function
        # scope).
        $totalSteps = $(if ($Variant -eq 'Desktop') { 10 } else { 5 })
        $ctx = @{ Step = 0 }

        function Invoke-BakeStep {
            param([string]$Name, [string]$Script, [int]$Timeout = 180, [int]$Retries = 0)
            $ctx.Step++
            $label = "[$($ctx.Step)/$totalSteps]"
            $maxAttempts = 1 + $Retries
            for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            Write-Log "Bake $label $Name$(if ($attempt -gt 1) { " (retry $($attempt-1)/$Retries)" })" -Activity
            $r = Invoke-LinuxVmCommand -VmName $vmName -BashCommand $Script `
                -IPAddress $BakeIPAddress -UserName 'memlabs' -Sudo `
                -TimeoutSeconds $Timeout -DisplayName "Bake: $Name"
            if ($r.CommandResult) {
                $lines = $(if ($r.ScriptBlockOutput) { ($r.ScriptBlockOutput -split "`n").Count } else { 0 })
                Write-Log "Bake $label $Name - OK ($lines lines)" -Success
                return $r
            }
            if ($attempt -lt $maxAttempts) {
                $backoff = $attempt * 15
                Write-Log "Bake $label $Name failed (exit=$($r.ExitCode)), retrying in ${backoff}s..." -Warning
                Start-Sleep -Seconds $backoff
                continue
            }
            $out = $(if ($r.ScriptBlockOutput) { $r.ScriptBlockOutput.Trim() } else { '(no output)' })
                if ($out.Length -gt 2000) { $out = '...' + $out.Substring($out.Length - 2000) }
                Write-Log "Bake $label FAILED: $Name (exit=$($r.ExitCode))" -Failure
                Write-Log $out -LogOnly
                throw "Bake FAILED at step $label '$Name' (exit=$($r.ExitCode)).`n`nLast output:`n$out`n`nVM '$vmName' left running at $BakeIPAddress for debugging.`nSSH: ssh -i `"$($keyPair.PrivateKeyPath)`" memlabs@$BakeIPAddress"
            }
        }

        # ── Step 1: System updates ───────────────────────────────────────
        $updTimeout = $(if ($Variant -eq 'Desktop') { 1200 } else { 600 })
        Invoke-BakeStep -Name "System updates (apt-get update + dist-upgrade)" -Timeout $updTimeout -Retries 2 `
            -Script (Get-LinuxScript -Name 'bake/01-system-updates' -IncludeAptRetry)

        # ── Step 2: Base packages ────────────────────────────────────────
        Invoke-BakeStep -Name "Base packages (HVL, qemu-guest-agent)" -Timeout 300 -Retries 2 `
            -Script (Get-LinuxScript -Name 'bake/02-base-packages' -IncludeAptRetry)

        # ── Step 3: Enable base services ─────────────────────────────────
        Invoke-BakeStep -Name "Enable base services" -Timeout 120 `
            -Script (Get-LinuxScript -Name 'bake/03-enable-base-services' -IncludeAptRetry)

        # ── Step 3b: Prevent maintenance-mode boot on fsck failure ───────
        Invoke-BakeStep -Name "Prevent maintenance-mode boot" -Timeout 60 `
            -Script (Get-LinuxScript -Name 'bake/03b-maintenance-prevention')

        # ── Step 4: DHCP watchdog service ────────────────────────────────
        Invoke-BakeStep -Name "DHCP watchdog service" -Timeout 60 `
            -Script (Get-LinuxScript -Name 'bake/04-dhcp-watchdog')

        if ($Variant -eq 'Desktop') {
            # ── Step 5: Desktop packages ─────────────────────────────────
            Invoke-BakeStep -Name "Desktop packages (GNOME, xrdp, tools)" -Timeout 1800 -Retries 2 `
                -Script (Get-LinuxScript -Name 'bake/05-desktop-packages' -IncludeAptRetry)

            # ── Step 6: Desktop services ─────────────────────────────────
            Invoke-BakeStep -Name "Enable desktop services" -Timeout 120 `
                -Script (Get-LinuxScript -Name 'bake/06-desktop-services')

            # ── Step 7: Microsoft repos + Edge + Intune ──────────────────
            Invoke-BakeStep -Name "Microsoft Edge + Intune" -Timeout 600 -Retries 2 `
                -Script (Get-LinuxScript -Name 'bake/07-edge-intune' -IncludeAptRetry)

            # ── Step 8: Desktop system configuration ─────────────────────
            Invoke-BakeStep -Name "Desktop system configuration" -Timeout 120 `
                -Script (Get-LinuxScript -Name 'bake/08-desktop-config')

            # ── Step 9: dash-to-panel extension ──────────────────────────
            Invoke-BakeStep -Name "dash-to-panel extension" -Timeout 120 `
                -Script (Get-LinuxScript -Name 'bake/09-dash-to-panel' -IncludeAptRetry)
        } # end Desktop-only steps

        # ── Validation ───────────────────────────────────────────────────
        $validationScript = $(if ($Variant -eq 'Desktop') {
            Get-LinuxScript -Name 'bake/validate-desktop'
        } else {
            Get-LinuxScript -Name 'bake/validate-server'
        })

        Invoke-BakeStep -Name "Validation" -Timeout 60 -Script $validationScript

        # ── Cleanup + shutdown ───────────────────────────────────────────
        # Only runs after validation passed. Removes the bake user, cleans
        # cloud-init state, and shuts down so the VHDX is pristine.
        Write-Log "Bake: all steps passed. Running cleanup and shutdown..." -Activity
        $cleanupResult = Invoke-LinuxVmCommand -VmName $vmName -IPAddress $BakeIPAddress `
            -UserName 'memlabs' -Sudo -TimeoutSeconds 120 `
            -DisplayName "Bake: Cleanup + shutdown" -BashCommand (Get-LinuxScript -Name 'bake/cleanup')
        # Cleanup+shutdown may report exit code 1 because the shutdown command
        # kills the SSH session before it can return. That's expected - check
        # for the success marker in output instead of exit code.
        if ($cleanupResult.ScriptBlockOutput -notmatch 'Cleanup complete') {
            $out = $(if ($cleanupResult.ScriptBlockOutput) { $cleanupResult.ScriptBlockOutput.Trim() } else { '(no output)' })
            Write-Log "Bake: cleanup script may not have completed fully:`n$out" -Warning
        }

        # ── Wait for shutdown ────────────────────────────────────────────
        Write-Log "Bake: waiting for VM to power off..."
        $shutdownDeadline = (Get-Date).AddMinutes(5)
        $cleanShutdown = $false
        while ((Get-Date) -lt $shutdownDeadline) {
            Start-Sleep -Seconds 5
            $state = (Get-VM -Name $vmName -ErrorAction SilentlyContinue).State
            if ($state -eq 'Off') { $cleanShutdown = $true; break }
        }
        if (-not $cleanShutdown) {
            Write-Log "Bake: VM did not power off within 5 min after shutdown command; forcing off." -Warning
            Stop-VM -Name $vmName -TurnOff -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-Log "Bake: VM shut down cleanly." -Success
        }

        $bakeSucceeded = $true
    }
    finally {
        # On success: remove the temp VM (keeps the VHDX).
        # On failure: leave the VM running for SSH/console debugging.
        # Stale VMs from failed runs are cleaned up at the top of the next invocation.
        $bakeVM = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if ($bakeVM) {
            if ($bakeSucceeded) {
                if ($bakeVM.State -ne 'Off') {
                    Stop-VM -VM $bakeVM -TurnOff -Force -ErrorAction SilentlyContinue
                }
                Disable-VMResourceMetering -VM $bakeVM -ErrorAction SilentlyContinue
                Remove-VM -VM $bakeVM -Force -ErrorAction SilentlyContinue
            }
            else {
                Disable-VMResourceMetering -VM $bakeVM -ErrorAction SilentlyContinue
                Write-Log "Bake: FAILED - VM '$vmName' left running for debugging:" -Warning
                Write-Log "  SSH:     ssh -i `"$($keyPair.PrivateKeyPath)`" memlabs@$BakeIPAddress" -Warning
                Write-Log "  Console: vmconnect localhost $vmName" -Warning
                Write-Log "  Cleanup: Stop-VM '$vmName' -TurnOff; Remove-VM '$vmName' -Force" -Warning
            }
        }
        Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Bake complete on $VhdxPath" -Success
    return $true
}


