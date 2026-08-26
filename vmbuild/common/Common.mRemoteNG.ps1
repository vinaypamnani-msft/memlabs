# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
##############################
### mRemoteNG Functions    ###
##############################

# ============================================================================
# mRemoteNG password-audit diagnostics (ALWAYS-ON)
# ----------------------------------------------------------------------------
# These exist to root-cause the recurring "password corrupted (decrypt failed:
# Decryption failed)" loop where EVERY password is re-flagged and "Repaired" on
# every build but the file never converges. Hypothesis: the audit decrypts with
# the provider's default KeyDerivationIterations while mRemoteNG.exe rewrites the
# file's KdfIterations to a different value on its side, so the derived key never
# matches across the script <-> GUI handoff.
#
# They run UNCONDITIONALLY for now so the very next build captures the failure
# window (the prior log didn't reach the mRemoteNG step). All output is -LogOnly
# so there is zero added console noise, and no password plaintext is ever logged
# (only blob lengths/prefixes, SHA256 file hashes, and iteration counts).
#
# TODO(mrng-diag): once the root cause is confirmed and the KDF-iteration fix is
# in, RE-GATE all of this behind a switch (e.g. $global:MRNGDiag mirroring
# $global:ProgressDiag, or env var MEMLABS_MRNG_DIAG=1) and make Write-MRNGDiag a
# no-op when the gate is off.
# ============================================================================

function Write-MRNGDiag {
    param([string]$Message)
    # TODO(mrng-diag): add early-return gate here once root cause is resolved.
    try {
        Write-Log "[MRNGDiag] $Message" -LogOnly
    }
    catch {}
}

# Read a member value (public or non-public property/field) via reflection.
# Used to inspect the AeadCryptographyProvider's iteration/cipher settings,
# which are not guaranteed to be public.
function Get-MRNGMemberValue {
    param($Object, [string]$Name)
    if (-not $Object) { return $null }
    $flags = [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance
    $t = $Object.GetType()
    try {
        $prop = $t.GetProperty($Name, $flags)
        if ($prop) { return $prop.GetValue($Object, $null) }
    }
    catch {}
    try {
        $field = $t.GetField($Name, $flags)
        if ($field) { return $field.GetValue($Object) }
    }
    catch {}
    return $null
}

# Set a member value (public or non-public property/field) via reflection.
# Returns $true on success. Used by the non-destructive decrypt probe to point a
# throwaway provider at the file's declared KdfIterations.
function Set-MRNGMemberValue {
    param($Object, [string]$Name, $Value)
    if (-not $Object) { return $false }
    $flags = [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance
    $t = $Object.GetType()
    try {
        $prop = $t.GetProperty($Name, $flags)
        if ($prop -and $prop.CanWrite) { $prop.SetValue($Object, $Value, $null); return $true }
    }
    catch {}
    try {
        $field = $t.GetField($Name, $flags)
        if ($field) { $field.SetValue($Object, $Value); return $true }
    }
    catch {}
    return $false
}

# Snapshot the crypto provider's effective key-derivation settings so we can
# compare them against the file's declared KdfIterations.
function Get-MRNGProviderSnapshot {
    param($Provider)
    $snap = @{ KeyDerivationIterations = "n/a"; BlockCipherMode = "n/a"; EncryptionEngine = "n/a" }
    if (-not $Provider) { return $snap }
    foreach ($propName in @("KeyDerivationIterations", "BlockCipherMode", "EncryptionEngine")) {
        $val = Get-MRNGMemberValue -Object $Provider -Name $propName
        if ($null -ne $val) { $snap[$propName] = "$val" }
    }
    return $snap
}

# Fingerprint the connection file on disk: SHA256, byte length, last-write time,
# the root encryption attributes (KdfIterations etc.), and how many nodes carry a
# password. Never reads or logs any password plaintext. Returns a hashtable, or
# $null when the file is absent.
function Get-MRNGFileFingerprint {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path $Path)) { return $null }
    $fp = @{
        Path          = $Path
        Sha256        = $null
        Length        = $null
        LastWriteUtc  = $null
        RootAttrs     = @{}
        PasswordNodes = 0
    }
    try {
        $item = Get-Item -Path $Path -ErrorAction Stop
        $fp.Length = $item.Length
        $fp.LastWriteUtc = $item.LastWriteTimeUtc.ToString("o")
    }
    catch {}
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $hashBytes = $sha.ComputeHash($bytes)
        $fp.Sha256 = ([System.BitConverter]::ToString($hashBytes)).Replace("-", "")
        $sha.Dispose()
    }
    catch {}
    try {
        [xml]$x = Get-Content -Path $Path -ErrorAction Stop
        $rootEl = $x.DocumentElement
        foreach ($attrName in @("EncryptionEngine", "BlockCipherMode", "KdfIterations", "FullFileEncryption", "Protected")) {
            $val = $rootEl.GetAttribute($attrName)
            if ($attrName -eq "Protected" -and $val -and $val.Length -gt 12) {
                $val = $val.Substring(0, 12) + "..."
            }
            $fp.RootAttrs[$attrName] = $val
        }
        $fp.PasswordNodes = @($x.SelectNodes("//Node") | Where-Object { -not [string]::IsNullOrEmpty($_.GetAttribute("Password")) }).Count
    }
    catch {}
    return $fp
}

# Render a fingerprint (from Get-MRNGFileFingerprint) to a single log line.
function Format-MRNGFingerprint {
    param($Fingerprint)
    if (-not $Fingerprint) { return "<no file>" }
    $ra = $Fingerprint.RootAttrs
    return ("sha256={0} len={1} lastWriteUtc={2} KdfIterations={3} EncryptionEngine={4} BlockCipherMode={5} FullFileEncryption={6} Protected={7} pwdNodes={8}" -f `
            $Fingerprint.Sha256, $Fingerprint.Length, $Fingerprint.LastWriteUtc, $ra["KdfIterations"], $ra["EncryptionEngine"], $ra["BlockCipherMode"], $ra["FullFileEncryption"], $ra["Protected"], $Fingerprint.PasswordNodes)
}

# Non-destructive probe: try to decrypt a password blob using the FILE's declared
# KdfIterations on a throwaway provider. If it succeeds where the default-iteration
# audit failed, that is the smoking gun confirming the iteration mismatch is the
# root cause. Does not modify the document or the real audit provider.
function Test-MRNGDecryptWithFileIterations {
    param(
        [string]$EncryptedPassword,
        $Key,
        [string]$FileKdfIterations,
        [string]$ExpectedPlaintext
    )
    if ([string]::IsNullOrEmpty($FileKdfIterations)) { return "skipped (no file KdfIterations)" }
    $iters = 0
    if (-not [int]::TryParse($FileKdfIterations, [ref]$iters)) { return "skipped (unparseable KdfIterations '$FileKdfIterations')" }
    $probeProvider = $null
    try {
        $probeProvider = New-Object mRemoteNG.Security.SymmetricEncryption.AeadCryptographyProvider
    }
    catch {
        return "error (cannot create probe provider: $($_.Exception.Message))"
    }
    $set = Set-MRNGMemberValue -Object $probeProvider -Name "KeyDerivationIterations" -Value $iters
    if (-not $set) { return "skipped (could not set KeyDerivationIterations=$iters on probe provider)" }
    try {
        $decrypted = $probeProvider.Decrypt($EncryptedPassword, $Key)
        if ($decrypted -ceq $ExpectedPlaintext) {
            return "SUCCESS with $iters iterations -- confirms iteration mismatch is the root cause"
        }
        return "decrypted but value mismatch (len=$($decrypted.Length)) with $iters iterations"
    }
    catch {
        return "still FAILED with $iters iterations: $($_.Exception.Message)"
    }
}

function Install-MRemoteNG {
    # Check standard install paths
    $mRemoteNGExe = $null
    $searchPaths = @(
        (Join-Path $env:ProgramData "memlabs\mRemoteNG\mRemoteNG.exe"),
        "$env:ProgramFiles\mRemoteNG\mRemoteNG.exe",
        "${env:ProgramFiles(x86)}\mRemoteNG\mRemoteNG.exe",
        "C:\ProgramData\chocolatey\lib\mremoteng\tools\mRemoteNG.exe"
    )
    foreach ($p in $searchPaths) {
        if (Test-Path $p) {
            $mRemoteNGExe = $p
            break
        }
    }

    if (-not $mRemoteNGExe) {
        Write-Log "mRemoteNG.exe not found. Skipping shortcut creation." -Warning -LogOnly
        return
    }

    # Create desktop shortcut pointing to our connection file
    $shortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "memlabs-mRemoteNG.lnk"
    $shouldRecreate = $false
    $expectedArgs = "/cons:`"$($Global:Common.MRemoteNGFilePath)`""
    if (Test-Path $shortcutPath) {
        # Verify existing shortcut points to the correct exe and has correct /cons: path
        try {
            $shell = New-Object -ComObject WScript.Shell
            $existing = $shell.CreateShortcut($shortcutPath)
            if ($existing.TargetPath -ne $mRemoteNGExe -or $existing.Arguments -ne $expectedArgs) {
                $shouldRecreate = $true
            }
        }
        catch {
            $shouldRecreate = $true
        }
    }
    else {
        $shouldRecreate = $true
    }
    if ($shouldRecreate) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $mRemoteNGExe
            $shortcut.Arguments = $expectedArgs
            $shortcut.WorkingDirectory = Split-Path $mRemoteNGExe
            $shortcut.Save()
            Write-Log "Created mRemoteNG desktop shortcut: $shortcutPath" -Success -LogOnly
        }
        catch {
            Write-Log "Failed to create mRemoteNG shortcut: $_" -Warning -LogOnly
        }
    }

    # Remove the default mRemoteNG shortcut(s) created by choco to avoid confusion
    $defaultShortcutPaths = @(
        Join-Path ([Environment]::GetFolderPath("Desktop")) "mRemoteNG.lnk"
        Join-Path ([Environment]::GetFolderPath("CommonDesktopDirectory")) "mRemoteNG.lnk"
    )
    foreach ($defaultLnk in $defaultShortcutPaths) {
        if (Test-Path $defaultLnk) {
            Remove-Item $defaultLnk -Force -ErrorAction SilentlyContinue
            Write-Log "Removed default mRemoteNG shortcut: $defaultLnk" -LogOnly -Verbose
        }
    }

    # Enable description tooltips in the connection tree so hovering shows VM info.
    Set-MRemoteNGSettings -InstallDir (Split-Path $mRemoteNGExe) `
        -ConnectionFilePath $Global:Common.MRemoteNGFilePath

    # Workaround: mRemoteNG 1.78.2 /cons: CLI argument is broken — GetStartupConnectionFileName()
    # reads OptionsConnectionsPage.Default.ConnectionFilePath but /cons: writes to the old
    # OptionsBackupPage.Default.BackupLocation (dead code path). Symlink the default confCons.xml
    # to our memlabs XML so mRemoteNG loads it without needing /cons:.
    # The nightly build is portable, so the primary path is the install directory (next to the exe).
    $memlabsXml = $Global:Common.MRemoteNGFilePath
    if ($memlabsXml -and (Test-Path $memlabsXml)) {
        $installDir = Split-Path $mRemoteNGExe
        $symlinkTargets = @(
            Join-Path $installDir "confCons.xml"
            Join-Path $env:LOCALAPPDATA "mRemoteNG\confCons.xml"
            Join-Path ([Environment]::GetFolderPath("ApplicationData")) "mRemoteNG\confCons.xml"
        )
        foreach ($defaultFile in $symlinkTargets) {
            try {
                $defaultDir = Split-Path $defaultFile
                if (-not (Test-Path $defaultDir)) {
                    New-Item -ItemType Directory -Path $defaultDir -Force | Out-Null
                }
                $item = Get-Item $defaultFile -ErrorAction SilentlyContinue
                $isCorrectSymlink = $item -and $item.LinkTarget -eq $memlabsXml
                if (-not $isCorrectSymlink) {
                    if (Test-Path $defaultFile) { Remove-Item $defaultFile -Force }
                    New-Item -ItemType SymbolicLink -Path $defaultFile -Target $memlabsXml -Force | Out-Null
                    Write-Log "Symlinked $defaultFile -> $memlabsXml" -LogOnly -Verbose
                }
            }
            catch {
                Write-Log "Could not create symlink at $defaultFile`: $_" -Warning -LogOnly
            }
        }
    }
}

function Format-MRemoteNGTooltip {
    # Build a human-readable multi-line description for mRemoteNG connection tooltips.
    # Replaces the raw JSON blob so hovering a connection shows useful VM info at a glance.
    param(
        [PSCustomObject]$Vm,
        [string]$CmVersion = "",
        [PSCustomObject[]]$VmListFull = @(),
        [string]$ResolvedIp = ""
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $vmIsLinux = Test-VmIsLinux -Vm $Vm

    # --- Line 1: Role description ---
    $roleLabel = switch ($Vm.Role) {
        'DC'               { 'Domain Controller' }
        'BDC'              { 'Backup Domain Controller' }
        'CAS'              { 'CAS Site Server' }
        'Primary'          { 'Primary Site Server' }
        'Secondary'        { 'Secondary Site Server' }
        'PassiveSite'      { 'Passive Site Server' }
        'SiteSystem'       { 'Site System' }
        'DomainMember'     { if ($Vm.deployedOS -match 'Server') { 'Domain Member (Server)' } else { 'Domain Member (Client)' } }
        'WorkgroupMember'  { 'Workgroup Member' }
        'InternetClient'   { 'Internet Client' }
        'AADClient'        { 'Entra ID Client' }
        'OSDClient'        { 'OSD Client' }
        'WSUS'             { 'WSUS Server' }
        'FileServer'       { 'File Server' }
        'SQLAO'            { 'SQL Always On' }
        'StandaloneRootCA' { 'Standalone Root CA' }
        'Proxy'            { 'Proxy' }
        'LinuxServer'      { 'Linux Server' }
        'LinuxClient'      { 'Linux Client' }
        default            { $Vm.Role }
    }
    $os = if ($Vm.deployedOS) { $Vm.deployedOS } elseif ($Vm.operatingSystem) { $Vm.operatingSystem } else { '' }
    if ($os) { $lines.Add("$roleLabel  `u{2022}  $os") } else { $lines.Add($roleLabel) }

    # --- Line 2: IP / Memory / vCPUs ---
    $infoParts = @()
    $ip = if (-not [string]::IsNullOrWhiteSpace($ResolvedIp)) { $ResolvedIp } elseif ($Vm.LastKnownIP) { $Vm.LastKnownIP } else { $null }
    if ($ip) { $infoParts += "IP: $ip" }
    if ($Vm.memory) { $infoParts += "$($Vm.memory) RAM" }
    if ($Vm.virtualProcs) {
        $cpuLabel = if ([int]$Vm.virtualProcs -eq 1) { 'vCPU' } else { 'vCPUs' }
        $infoParts += "$($Vm.virtualProcs) $cpuLabel"
    }
    if ($infoParts.Count -gt 0) { $lines.Add($infoParts -join '  `u{2022}  ') }

    # --- Domain ---
    if ($Vm.Domain) { $lines.Add("Domain: $($Vm.Domain)") }

    # --- Site info (CM roles) ---
    if ($Vm.SiteCode) {
        $siteLine = "Site: $($Vm.SiteCode)"
        if ($Vm.ParentSiteCode) { $siteLine += " -> $($Vm.ParentSiteCode)" }
        if ($Vm.siteName) { $siteLine += " ($($Vm.siteName))" }
        $lines.Add($siteLine)
    }
    if ($CmVersion -and $Vm.Role -in 'CAS', 'Primary', 'Secondary', 'SiteSystem', 'PassiveSite') {
        $lines.Add("ConfigMgr: $CmVersion")
    }

    # --- SQL ---
    if ($Vm.SqlVersion) {
        $sqlLine = "SQL: $($Vm.SqlVersion)"
        if ($Vm.sqlInstanceName -and $Vm.sqlInstanceName -ne 'MSSQLSERVER') { $sqlLine += " ($($Vm.sqlInstanceName))" }
        if ($Vm.RemoteSQLVM) { $sqlLine += " (remote: $($Vm.RemoteSQLVM))" }
        $lines.Add($sqlLine)
    } elseif ($Vm.Role -in 'CAS', 'Primary' -and $VmListFull.Count -gt 0) {
        # Show remote SQL if this site server uses one
        $remoteSql = $Vm.RemoteSQLVM
        if ($remoteSql) {
            $sqlVm = $VmListFull | Where-Object { $_.vmName -eq $remoteSql } | Select-Object -First 1
            $sqlLine = "SQL: $remoteSql"
            if ($sqlVm.SqlVersion) { $sqlLine += " ($($sqlVm.SqlVersion))" }
            $lines.Add($sqlLine)
        }
    }

    # --- SQLAO details ---
    if ($Vm.Role -eq 'SQLAO') {
        if ($Vm.OtherNode) { $lines.Add("AG Partner: $($Vm.OtherNode)") }
        if ($Vm.AlwaysOnListenerName) { $lines.Add("Listener: $($Vm.AlwaysOnListenerName)") }
        if ($Vm.ClusterName) { $lines.Add("Cluster: $($Vm.ClusterName)") }
    }

    # --- Site System roles ---
    if ($Vm.Role -eq 'SiteSystem') {
        $sr = @()
        if ($Vm.installMP)     { $sr += 'MP' }
        if ($Vm.installDP)     { $sr += 'DP' }
        if ($Vm.installSUP -or $Vm.InstallSUP) { $sr += 'SUP' }
        if ($Vm.InstallRP)     { $sr += 'RP' }
        if ($Vm.InstallSMSProv) { $sr += 'SMS Provider' }
        if ($sr.Count -gt 0)   { $lines.Add("Roles: $($sr -join ', ')") }
    } else {
        # Non-SiteSystem with SUP (e.g. Primary w/ co-located SUP)
        if ($Vm.installSUP -or $Vm.InstallSUP) { $lines.Add('WSUS / SUP co-located') }
    }

    # --- Features ---
    $features = @()
    if ($Vm.InstallCA) {
        $caLabel = 'Issuing CA'
        if ($Vm.SubordinateCA -or $Vm.UseOfflineRoot) { $caLabel += ' (Subordinate)' }
        $features += $caLabel
    }
    if ($Vm.tpmEnabled)  { $features += 'TPM' }
    if ($Vm.BitLocker)   { $features += 'BitLocker' }
    if ($Vm.useProxy)    { $features += 'Proxy' }
    if ($Vm.enablePullDP) { $features += 'Pull DP' }
    if ($Vm.InstallRP -and $Vm.Role -ne 'SiteSystem') { $features += 'Reporting Point' }
    if ($features.Count -gt 0) { $lines.Add($features -join '  `u{2022}  ') }

    # --- User ---
    if ($Vm.domainUser) { $lines.Add("User: $($Vm.domainUser)") }

    # --- Linux extras ---
    if ($vmIsLinux) {
        if ($Vm.Role -eq 'Proxy') {
            $lines.Add("Squid logs: /var/log/squid")
            if ($ip) { $lines.Add("Proxy Admin: http://${ip}:8443") }
        }
        $rdpOn = ($Vm.PSObject.Properties.Name -contains 'enableRDP') -and [bool]$Vm.enableRDP
        if ($rdpOn) { $lines.Add('xRDP enabled') }
        $joinOn = ($Vm.PSObject.Properties.Name -contains 'joinDomain') -and [bool]$Vm.joinDomain
        if ($joinOn) { $lines.Add('AD domain joined') }
    }

    # --- Network ---
    if ($Vm.network) { $lines.Add("Network: $($Vm.network)") }

    return ($lines -join "`n")
}

function Set-MRemoteNGSettings {
    # Enable description tooltips and pin mRemoteNG to the generated connection file.
    # Handles both portable (mRemoteNG.settings next to exe) and
    # non-portable (user.config in %LocalAppData%) editions.
    param(
        [string]$InstallDir,
        [string]$ConnectionFilePath
    )

    if (-not $InstallDir) { return }

    $portableSettings = [ordered]@{
        ShowDescriptionTooltipsInTree = 'True'
    }
    if (-not [string]::IsNullOrWhiteSpace($ConnectionFilePath)) {
        # ConnectionFilePath is used by older 1.78 nightlies. Current builds use
        # LoadConsFromCustomLocation + CustomConsPath. Write both generations.
        $portableSettings['ConnectionFilePath'] = $ConnectionFilePath
        $portableSettings['LoadConsFromCustomLocation'] = 'True'
        $portableSettings['CustomConsPath'] = $ConnectionFilePath
    }

    # --- Portable edition: mRemoteNG.settings ---
    $portableFile = Join-Path $InstallDir 'mRemoteNG.settings'
    try {
        if (Test-Path $portableFile) {
            [xml]$sx = Get-Content -Path $portableFile -Raw
        }
        else {
            [xml]$sx = '<?xml version="1.0" encoding="utf-8"?><settings><localSettings></localSettings><globalSettings></globalSettings></settings>'
        }
        $local = $sx.SelectSingleNode('//localSettings')
        if (-not $local) {
            $local = $sx.CreateElement('localSettings')
            [void]$sx.DocumentElement.AppendChild($local)
        }
        $portableChanged = $false
        foreach ($setting in $portableSettings.GetEnumerator()) {
            $node = $local.SelectSingleNode("setting[@name='$($setting.Key)']")
            if (-not $node) {
                $node = $sx.CreateElement('setting')
                $node.SetAttribute('name', $setting.Key)
                $node.InnerText = $setting.Value
                [void]$local.AppendChild($node)
                $portableChanged = $true
            }
            elseif ($node.InnerText -ne $setting.Value) {
                $node.InnerText = $setting.Value
                $portableChanged = $true
            }
        }
        if ($portableChanged) {
            $sx.Save($portableFile)
            Write-Log "mRemoteNG: updated portable settings in $portableFile" -LogOnly -Verbose
        }
    }
    catch {
        Write-Log "mRemoteNG: could not update portable settings: $_" -Warning -LogOnly
    }

    # --- Non-portable edition: user.config in %LocalAppData% ---
    try {
        $userSettings = @(
            [pscustomobject]@{
                Section = '//userSettings/mRemoteNG.Properties.OptionsAppearancePage'
                Name    = 'ShowDescriptionTooltipsInTree'
                Value   = 'True'
            }
        )
        if (-not [string]::IsNullOrWhiteSpace($ConnectionFilePath)) {
            $userSettings += [pscustomobject]@{
                Section = '//userSettings/mRemoteNG.Properties.OptionsConnectionsPage'
                Name    = 'ConnectionFilePath'
                Value   = $ConnectionFilePath
            }
            $userSettings += [pscustomobject]@{
                Section = '//userSettings/mRemoteNG.Properties.OptionsBackupPage'
                Name    = 'LoadConsFromCustomLocation'
                Value   = 'True'
            }
            $userSettings += [pscustomobject]@{
                Section = '//userSettings/mRemoteNG.Properties.OptionsBackupPage'
                Name    = 'CustomConsPath'
                Value   = $ConnectionFilePath
            }
        }

        $userConfigs = @(Get-ChildItem -Path "$env:LOCALAPPDATA\mRemoteNG" -Filter 'user.config' -Recurse -ErrorAction SilentlyContinue)
        foreach ($uc in $userConfigs) {
            [xml]$ucx = Get-Content -Path $uc.FullName -Raw
            $userConfigChanged = $false
            foreach ($setting in $userSettings) {
                $section = $ucx.SelectSingleNode($setting.Section)
                if (-not $section) { continue }
                $existing = $section.SelectSingleNode("setting[@name='$($setting.Name)']")
                if (-not $existing) {
                    $existing = $ucx.CreateElement('setting')
                    $existing.SetAttribute('name', $setting.Name)
                    $existing.SetAttribute('serializeAs', 'String')
                    $valueNode = $ucx.CreateElement('value')
                    [void]$existing.AppendChild($valueNode)
                    [void]$section.AppendChild($existing)
                }
                else {
                    $valueNode = $existing.SelectSingleNode('value')
                    if (-not $valueNode) {
                        $valueNode = $ucx.CreateElement('value')
                        [void]$existing.AppendChild($valueNode)
                    }
                }
                if ($valueNode.InnerText -ne $setting.Value) {
                    $valueNode.InnerText = $setting.Value
                    $userConfigChanged = $true
                }
            }
            if ($userConfigChanged) {
                $ucx.Save($uc.FullName)
                Write-Log "mRemoteNG: updated settings in $($uc.FullName)" -LogOnly -Verbose
            }
        }
    }
    catch {
        Write-Log "mRemoteNG: could not update user.config: $_" -Warning -LogOnly
    }
}

function Get-MRemoteNGPassword {
    # Encrypt password using mRemoteNG's BouncyCastle-based AES-GCM encryption.
    # Same pattern as Get-RDCManPassword loading rdcman.dll.
    $mRNGPath = $null
    $searchPaths = @(
        (Join-Path $env:ProgramData "memlabs\mRemoteNG"),
        "$env:ProgramFiles\mRemoteNG",
        "${env:ProgramFiles(x86)}\mRemoteNG"
    )
    foreach ($p in $searchPaths) {
        if (Test-Path "$p\mRemoteNG.exe") {
            $mRNGPath = $p
            break
        }
    }

    if (-not $mRNGPath) {
        Write-Log "mRemoteNG not found. Cannot encrypt password." -Warning -LogOnly
        return $null
    }

    $bouncyCastleDll = Join-Path $mRNGPath "BouncyCastle.Crypto.dll"
    if (-not (Test-Path $bouncyCastleDll)) {
        $bouncyCastleDll = Get-ChildItem -Path $mRNGPath -Filter "BouncyCastle*.dll" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
        if (-not $bouncyCastleDll) {
            Write-Log "BouncyCastle DLL not found in $mRNGPath. Cannot encrypt password." -Warning -LogOnly
            return $null
        }
    }

    try {
        $plaintext = $Common.LocalAdmin.GetNetworkCredential().Password

        # .NET 10 self-contained builds ship mRemoteNG.dll (managed) + mRemoteNG.exe (native host).
        # Old .NET Framework builds (choco 1.76) only have the managed .exe.
        $mRNGAssembly = Join-Path $mRNGPath "mRemoteNG.dll"
        if (-not (Test-Path $mRNGAssembly)) {
            $mRNGAssembly = Join-Path $mRNGPath "mRemoteNG.exe"
        }

        # Try loading inline first (pwsh/.NET Core — works for .NET 10 nightly builds).
        # Fall back to 32-bit Windows PowerShell for old .NET Framework x86 builds.
        $encrypted = $null
        try {
            Add-Type -Path $bouncyCastleDll -ErrorAction Stop
            [System.Reflection.Assembly]::LoadFile($mRNGAssembly) | Out-Null
            $cp = New-Object mRemoteNG.Security.SymmetricEncryption.AeadCryptographyProvider
            $key = ConvertTo-SecureString 'mR3m' -AsPlainText -Force
            $encrypted = $cp.Encrypt($plaintext, $key)
        }
        catch {
            # Inline load failed (likely old .NET Framework build) — try 32-bit WinPS
            $ps32 = Join-Path $env:SystemRoot "SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
            if (Test-Path $ps32) {
                $scriptText = @"
Add-Type -Path '$bouncyCastleDll' -ErrorAction Stop
[System.Reflection.Assembly]::LoadFile('$mRNGAssembly') | Out-Null
`$cp = New-Object mRemoteNG.Security.SymmetricEncryption.AeadCryptographyProvider
`$key = ConvertTo-SecureString 'mR3m' -AsPlainText -Force
`$cp.Encrypt('$($plaintext -replace "'","''")', `$key)
"@
                $result = & $ps32 -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $scriptText 2>&1
                if ($LASTEXITCODE -eq 0 -and $result -and $result -isnot [System.Management.Automation.ErrorRecord]) {
                    $encrypted = ($result | Select-Object -Last 1).ToString().Trim()
                }
                else {
                    Write-Log "32-bit PowerShell encryption also failed: $result" -Warning -LogOnly
                }
            }
        }

        if ($encrypted) {
            return $encrypted
        }

        Write-Log "Could not encrypt password with any PowerShell host." -Warning -LogOnly
        return $null
    }
    catch {
        Write-Log "Failed to encrypt password via mRemoteNG assemblies: $_" -Warning -LogOnly
        return $null
    }
}

function Repair-MRemoteNGPasswords {
    # Audit all Password attributes in the mRemoteNG XML document.
    # Every non-empty Password should decrypt to $Common.LocalAdmin's plaintext.
    # If decryption fails (corrupted) or returns wrong value, replace with a
    # freshly encrypted password. Returns $true if any were repaired.
    param(
        [xml]$Doc,
        [string]$FreshEncryptedPassword
    )

    if ([string]::IsNullOrEmpty($FreshEncryptedPassword)) {
        return $false
    }

    # Try to create the crypto provider for decryption validation.
    # Assemblies should already be loaded from Get-MRemoteNGPassword earlier.
    $cp = $null
    $key = $null
    $expectedPlaintext = $null
    try {
        $cp = New-Object mRemoteNG.Security.SymmetricEncryption.AeadCryptographyProvider
        $key = ConvertTo-SecureString 'mR3m' -AsPlainText -Force
        $expectedPlaintext = $Common.LocalAdmin.GetNetworkCredential().Password
    }
    catch {
        Write-Log "mRemoteNG password audit: cannot load crypto provider; skipping. $_" -Warning -LogOnly
        return $false
    }

    # ALWAYS-ON diagnostics: capture the provider's effective iteration count and
    # the file's declared KdfIterations up front. A mismatch here is the prime
    # suspect for the recurring "Decryption failed" loop.
    # TODO(mrng-diag): re-gate behind a switch once root cause is resolved.
    $providerSnapshot = Get-MRNGProviderSnapshot -Provider $cp
    $providerIterations = $providerSnapshot["KeyDerivationIterations"]
    $fileKdfIterations = $null
    try { $fileKdfIterations = $Doc.DocumentElement.GetAttribute("KdfIterations") } catch {}
    $iterationMismatch = ("$providerIterations" -ne "$fileKdfIterations")
    Write-MRNGDiag ("audit start: provider KeyDerivationIterations=$providerIterations BlockCipherMode=$($providerSnapshot['BlockCipherMode']) EncryptionEngine=$($providerSnapshot['EncryptionEngine'])")
    Write-MRNGDiag ("audit iteration check: file=$fileKdfIterations provider=$providerIterations mismatch=$iterationMismatch")

    $repaired = $false
    $checkedCount = 0
    $nodes = $Doc.SelectNodes("//Node")
    foreach ($node in $nodes) {
        $pwd = $node.GetAttribute("Password")
        if ([string]::IsNullOrEmpty($pwd)) { continue }

        # Container nodes are folders and carry no real credential (children use
        # their own). A non-empty container Password is a stale blob from an older
        # mRemoteNG/version that we cannot re-decrypt, and was the source of the
        # never-converging "decrypt failed" loop. Blank it (one-time cleanup) and
        # skip the decrypt audit instead of flagging it corrupted every run.
        if ($node.GetAttribute("Type") -eq "Container") {
            $node.SetAttribute("Password", "")
            $repaired = $true
            Write-MRNGDiag ("node '$($node.GetAttribute('Name'))' is Container: blanked stale password, skipping decrypt audit")
            continue
        }

        $checkedCount++
        $nodeName = $node.GetAttribute("Name")
        $pwdLen = $pwd.Length
        $pwdPrefix = if ($pwdLen -ge 8) { $pwd.Substring(0, 8) } else { $pwd }
        Write-MRNGDiag ("node '$nodeName': blobLen=$pwdLen blobPrefix=$pwdPrefix")
        try {
            $decrypted = $cp.Decrypt($pwd, $key)
            if ($decrypted -cne $expectedPlaintext) {
                Write-Log "mRemoteNG password audit: '$nodeName' decrypts to wrong value. Repairing." -Warning
                Write-MRNGDiag ("node '$nodeName' decrypt WRONG-VALUE: decryptedLen=$($decrypted.Length) expectedLen=$($expectedPlaintext.Length) file=$fileKdfIterations provider=$providerIterations mismatch=$iterationMismatch")
                $node.SetAttribute("Password", $FreshEncryptedPassword)
                $repaired = $true
            }
            else {
                Write-MRNGDiag ("node '$nodeName' decrypt OK")
            }
        }
        catch {
            Write-Log "mRemoteNG password audit: '$nodeName' password corrupted (decrypt failed: $_). Repairing." -Warning
            # ALWAYS-ON diag: full exception detail + non-destructive decrypt probe
            # using the file's own KdfIterations. TODO(mrng-diag): re-gate once fixed.
            $exType = $_.Exception.GetType().FullName
            $exMsg = $_.Exception.Message
            $innerMsg = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { "<none>" }
            Write-MRNGDiag ("node '$nodeName' decrypt FAILED: file=$fileKdfIterations provider=$providerIterations mismatch=$iterationMismatch exType=$exType exMsg=$exMsg innerMsg=$innerMsg")
            $probeResult = Test-MRNGDecryptWithFileIterations -EncryptedPassword $pwd -Key $key -FileKdfIterations $fileKdfIterations -ExpectedPlaintext $expectedPlaintext
            Write-MRNGDiag ("node '$nodeName' decrypt-with-file-iterations probe: $probeResult")
            $node.SetAttribute("Password", $FreshEncryptedPassword)
            $repaired = $true
        }
    }

    if ($repaired) {
        Write-Log "mRemoteNG password audit: repaired corrupted passwords (checked $checkedCount nodes)." -Warning
    }
    else {
        Write-Log "mRemoteNG password audit: all $checkedCount passwords verified OK." -LogOnly -Verbose
    }

    return $repaired
}

function Get-MRemoteNGDeterministicGuid {
    param([string]$Seed)
    # Generate a deterministic GUID from a seed string so IDs remain stable across regenerations.
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Seed)
    $hash = $md5.ComputeHash($bytes)
    $md5.Dispose()
    return [guid]::new($hash).ToString()
}

function New-MRemoteNGXmlDocument {
    # Build a fresh mRemoteNG confCons XML document programmatically.
    [xml]$doc = '<?xml version="1.0" encoding="utf-8"?><Connections />'
    $root = $doc.DocumentElement

    $root.SetAttribute("xmlns:mrng", "http://mremoteng.org")
    $root.SetAttribute("Name", "MemLabs")
    $root.SetAttribute("Export", "false")
    $root.SetAttribute("EncryptionEngine", "AES")
    $root.SetAttribute("BlockCipherMode", "GCM")
    $root.SetAttribute("KdfIterations", "1000")
    $root.SetAttribute("FullFileEncryption", "false")
    # Protected hash for default (no custom master password) — required or mRemoteNG crashes with NullReferenceException
    $root.SetAttribute("Protected", "zd4H/+kOmTb3uDN3ehFiYDE5SiS79p+qWRZkMBpQjzaiU4A5rA66CcSULCGAPhxpZRrcfKy7A7NMMG4jgBSD0SPG")
    $root.SetAttribute("ConfVersion", "2.8")

    return $doc
}

function Get-MRemoteNGGroupForVM {
    <#
    .SYNOPSIS
        Returns the role-based group name for a VM (Clients, DomainServers, MECMServers, Servers).
    #>
    param($Vm, $VmListFull)

    switch ($Vm.Role) {
        "DC"               { return "DomainServers" }
        "BDC"              { return "DomainServers" }
        "FileServer"       { return "DomainServers" }
        "StandaloneRootCA" { return "DomainServers" }
        "CAS"              { return "MECMServers" }
        "Primary"          { return "MECMServers" }
        "Secondary"        { return "MECMServers" }
        "SiteSystem"       { return "MECMServers" }
        "PassiveSite"      { return "MECMServers" }
        "OSDClient"        { return "Clients" }
        "AADClient"        { return "Clients" }
        "InternetClient"   { return "Clients" }
        "SQLAO" {
            # SQLAO hosting a site DB → MECMServers, otherwise Servers
            $primaryNode = $Vm
            if (-not $Vm.OtherNode) {
                $primaryNode = $VmListFull | Where-Object { $_.OtherNode -eq $Vm.vmName } | Select-Object -First 1
                if (-not $primaryNode) { $primaryNode = $Vm }
            }
            $siteServer = $VmListFull | Where-Object { $_.RemoteSQLVM -eq $primaryNode.vmName -and $_.Role -in "Primary", "CAS" }
            if ($siteServer) { return "MECMServers" }
            return "Servers"
        }
        "WSUS" {
            if ($Vm.installSUP -or $Vm.InstallSUP) { return "MECMServers" }
            return "Servers"
        }
        "DomainMember" {
            if ($Vm.InstallCA) { return "DomainServers" }
            # SQL hosting a site DB → MECMServers
            if ($Vm.SqlVersion) {
                $siteServer = $VmListFull | Where-Object { $_.RemoteSQLVM -eq $Vm.vmName -and $_.Role -in "Primary", "CAS" }
                if ($siteServer) { return "MECMServers" }
            }
            $isServer = $Vm.deployedOS -match "Server"
            if ($isServer) { return "Servers" }
            return "Clients"
        }
        "WorkgroupMember" {
            $isServer = $Vm.deployedOS -match "Server"
            if ($isServer) { return "Servers" }
            return "Clients"
        }
        default { return "Servers" }
    }
}

function New-MRemoteNGContainerNode {
    param(
        [xml]$Doc,
        [string]$Name,
        [string]$Username = "",
        [string]$Domain = "",
        [string]$Password = "",
        [string]$Protocol = "RDP",
        [string]$Port = "3389",
        [bool]$Expanded = $true
    )

    $node = $Doc.CreateElement("Node")
    $node.SetAttribute("Name", $Name)
    $node.SetAttribute("Type", "Container")
    $node.SetAttribute("Expanded", $Expanded.ToString().ToLower())
    $node.SetAttribute("Descr", "MemLabs Auto Generated")
    $node.SetAttribute("Icon", "mRemoteNG")
    $node.SetAttribute("Panel", "General")
    $node.SetAttribute("TabColor", "")
    $node.SetAttribute("ConnectionFrameColor", "None")
    $node.SetAttribute("Id", (Get-MRemoteNGDeterministicGuid -Seed "container:$Name"))
    $node.SetAttribute("Username", $Username)
    $node.SetAttribute("Domain", $Domain)
    # Containers are folders only. With no Inheritance element present, mRemoteNG
    # default behavior is that each child Connection uses its OWN credentials, not
    # the parent's. A container Password is dead weight that we cannot reliably
    # re-decrypt across mRemoteNG/version changes, which produced the recurring
    # "password corrupted (decrypt failed)" audit loop. Always leave it empty.
    $node.SetAttribute("Password", "")
    $node.SetAttribute("Hostname", "")
    $node.SetAttribute("Protocol", $Protocol)
    $node.SetAttribute("RdpVersion", "rdc10")
    $node.SetAttribute("SSHTunnelConnectionName", "")
    $node.SetAttribute("OpeningCommand", "")
    $node.SetAttribute("SSHOptions", "")
    $node.SetAttribute("PuttySession", "Default Settings")
    $node.SetAttribute("Port", $Port)
    $node.SetAttribute("ConnectToConsole", "false")
    $node.SetAttribute("UseCredSsp", "true")
    $node.SetAttribute("RenderingEngine", "IE")
    $node.SetAttribute("ICAEncryptionStrength", "EncrBasic")
    $node.SetAttribute("RDPAuthenticationLevel", "NoAuth")
    $node.SetAttribute("RDPMinutesToIdleTimeout", "0")
    $node.SetAttribute("RDPAlertIdleTimeout", "false")
    $node.SetAttribute("LoadBalanceInfo", "")
    $node.SetAttribute("Colors", "Colors16Bit")
    $node.SetAttribute("Resolution", "FitToWindow")
    $node.SetAttribute("AutomaticResize", "true")
    $node.SetAttribute("DisplayWallpaper", "false")
    $node.SetAttribute("DisplayThemes", "false")
    $node.SetAttribute("EnableFontSmoothing", "false")
    $node.SetAttribute("EnableDesktopComposition", "false")
    $node.SetAttribute("DisableFullWindowDrag", "false")
    $node.SetAttribute("DisableMenuAnimations", "false")
    $node.SetAttribute("DisableCursorShadow", "false")
    $node.SetAttribute("DisableCursorBlinking", "false")
    $node.SetAttribute("CacheBitmaps", "false")
    $node.SetAttribute("RedirectDiskDrives", "Local")
    $node.SetAttribute("RedirectDiskDrivesCustom", "")
    $node.SetAttribute("RedirectPorts", "false")
    $node.SetAttribute("RedirectPrinters", "false")
    $node.SetAttribute("RedirectClipboard", "true")
    $node.SetAttribute("RedirectSmartCards", "false")
    $node.SetAttribute("RedirectSound", "DoNotPlay")
    $node.SetAttribute("SoundQuality", "Dynamic")
    $node.SetAttribute("RedirectAudioCapture", "false")
    $node.SetAttribute("RedirectKeys", "true")
    $node.SetAttribute("Connected", "false")
    $node.SetAttribute("PreExtApp", "")
    $node.SetAttribute("PostExtApp", "")
    $node.SetAttribute("MacAddress", "")
    $node.SetAttribute("UserField", "")
    $node.SetAttribute("EnvironmentTags", "")
    $node.SetAttribute("Favorite", "false")
    $node.SetAttribute("ExtApp", "")
    $node.SetAttribute("StartProgram", "")
    $node.SetAttribute("StartProgramWorkDir", "")
    $node.SetAttribute("VNCCompression", "CompNone")
    $node.SetAttribute("VNCEncoding", "EncHextile")
    $node.SetAttribute("VNCAuthMode", "AuthVNC")
    $node.SetAttribute("VNCProxyType", "ProxyNone")
    $node.SetAttribute("VNCProxyIP", "")
    $node.SetAttribute("VNCProxyPort", "0")
    $node.SetAttribute("VNCProxyUsername", "")
    $node.SetAttribute("VNCProxyPassword", "")
    $node.SetAttribute("VNCColors", "ColNormal")
    $node.SetAttribute("VNCSmartSizeMode", "SmartSAspect")
    $node.SetAttribute("VNCViewOnly", "false")
    $node.SetAttribute("RDGatewayUsageMethod", "Never")
    $node.SetAttribute("RDGatewayHostname", "")
    $node.SetAttribute("RDGatewayUseConnectionCredentials", "Yes")
    $node.SetAttribute("RDGatewayExternalCredentialProvider", "None")
    $node.SetAttribute("RDGatewayUserViaAPI", "")
    $node.SetAttribute("RDGatewayUsername", "")
    $node.SetAttribute("RDGatewayPassword", "")
    $node.SetAttribute("RDGatewayDomain", "")
    $node.SetAttribute("UseRCG", "false")
    $node.SetAttribute("UseRestrictedAdmin", "false")
    $node.SetAttribute("UserViaAPI", "")
    $node.SetAttribute("EC2InstanceId", "")
    $node.SetAttribute("EC2Region", "eu-central-1")
    $node.SetAttribute("ExternalCredentialProvider", "None")
    $node.SetAttribute("ExternalAddressProvider", "None")
    $node.SetAttribute("VaultOpenbaoMount", "")
    $node.SetAttribute("VaultOpenbaoRole", "")
    $node.SetAttribute("VaultOpenbaoSecretEngine", "Kv")

    return $node
}

function New-MRemoteNGConnectionNode {
    param(
        [xml]$Doc,
        [string]$Name,
        [string]$DisplayName,
        [string]$Hostname,
        [string]$Protocol = "RDP",
        [string]$Port = "3389",
        [string]$Description = "",
        [string]$Username = "",
        [string]$Domain = "",
        [string]$Password = "",
        [string]$Id = "",
        [string]$PuttySession = "Default Settings",
        [string]$VmId = "",
        [bool]$UseEnhancedMode = $false
    )

    $node = $Doc.CreateElement("Node")
    $node.SetAttribute("Name", $DisplayName)
    $node.SetAttribute("Type", "Connection")
    $node.SetAttribute("Descr", $Description)
    $node.SetAttribute("Icon", "mRemoteNG")
    $node.SetAttribute("Panel", "General")
    $node.SetAttribute("TabColor", "")
    $node.SetAttribute("ConnectionFrameColor", "None")
    $node.SetAttribute("Id", $Id)
    $node.SetAttribute("Username", $Username)
    $node.SetAttribute("Domain", $Domain)
    $node.SetAttribute("Password", $Password)
    $node.SetAttribute("Hostname", $Hostname)
    $node.SetAttribute("Protocol", $Protocol)
    $node.SetAttribute("RdpVersion", "rdc10")
    $node.SetAttribute("SSHTunnelConnectionName", "")
    $node.SetAttribute("OpeningCommand", "")
    $node.SetAttribute("SSHOptions", "")
    $node.SetAttribute("PuttySession", $PuttySession)
    $node.SetAttribute("Port", $Port)
    $node.SetAttribute("ConnectToConsole", "false")
    $node.SetAttribute("UseCredSsp", $(if ($Protocol -eq "RDP") { "true" } else { "false" }))
    $node.SetAttribute("RenderingEngine", "IE")
    $node.SetAttribute("ICAEncryptionStrength", "EncrBasic")
    $node.SetAttribute("RDPAuthenticationLevel", "NoAuth")
    $node.SetAttribute("RDPMinutesToIdleTimeout", "0")
    $node.SetAttribute("RDPAlertIdleTimeout", "false")
    $node.SetAttribute("LoadBalanceInfo", "")
    $node.SetAttribute("Colors", "Colors16Bit")
    $node.SetAttribute("Resolution", "FitToWindow")
    $node.SetAttribute("AutomaticResize", "true")
    $node.SetAttribute("DisplayWallpaper", "false")
    $node.SetAttribute("DisplayThemes", "false")
    $node.SetAttribute("EnableFontSmoothing", "false")
    $node.SetAttribute("EnableDesktopComposition", "false")
    $node.SetAttribute("DisableFullWindowDrag", "false")
    $node.SetAttribute("DisableMenuAnimations", "false")
    $node.SetAttribute("DisableCursorShadow", "false")
    $node.SetAttribute("DisableCursorBlinking", "false")
    $node.SetAttribute("CacheBitmaps", "false")
    $node.SetAttribute("RedirectDiskDrives", "Local")
    $node.SetAttribute("RedirectDiskDrivesCustom", "")
    $node.SetAttribute("RedirectPorts", "false")
    $node.SetAttribute("RedirectPrinters", "false")
    $node.SetAttribute("RedirectClipboard", "true")
    $node.SetAttribute("RedirectSmartCards", "false")
    $node.SetAttribute("RedirectSound", "DoNotPlay")
    $node.SetAttribute("SoundQuality", "Dynamic")
    $node.SetAttribute("RedirectAudioCapture", "false")
    $node.SetAttribute("RedirectKeys", "true")
    $node.SetAttribute("Connected", "false")
    $node.SetAttribute("PreExtApp", "")
    $node.SetAttribute("PostExtApp", "")
    $node.SetAttribute("MacAddress", "")
    $node.SetAttribute("UserField", "")
    $node.SetAttribute("EnvironmentTags", "")
    $node.SetAttribute("Favorite", "false")
    $node.SetAttribute("ExtApp", "")
    $node.SetAttribute("StartProgram", "")
    $node.SetAttribute("StartProgramWorkDir", "")
    $node.SetAttribute("VNCCompression", "CompNone")
    $node.SetAttribute("VNCEncoding", "EncHextile")
    $node.SetAttribute("VNCAuthMode", "AuthVNC")
    $node.SetAttribute("VNCProxyType", "ProxyNone")
    $node.SetAttribute("VNCProxyIP", "")
    $node.SetAttribute("VNCProxyPort", "0")
    $node.SetAttribute("VNCProxyUsername", "")
    $node.SetAttribute("VNCProxyPassword", "")
    $node.SetAttribute("VNCColors", "ColNormal")
    $node.SetAttribute("VNCSmartSizeMode", "SmartSAspect")
    $node.SetAttribute("VNCViewOnly", "false")
    $node.SetAttribute("RDGatewayUsageMethod", "Never")
    $node.SetAttribute("RDGatewayHostname", "")
    $node.SetAttribute("RDGatewayUseConnectionCredentials", "Yes")
    $node.SetAttribute("RDGatewayExternalCredentialProvider", "None")
    $node.SetAttribute("RDGatewayUserViaAPI", "")
    $node.SetAttribute("RDGatewayUsername", "")
    $node.SetAttribute("RDGatewayPassword", "")
    $node.SetAttribute("RDGatewayDomain", "")

    if (-not [string]::IsNullOrWhiteSpace($VmId)) {
        $node.SetAttribute("VmId", $VmId)
        $node.SetAttribute("UseVmId", "true")
        $node.SetAttribute("UseEnhancedMode", $UseEnhancedMode.ToString().ToLower())
    }

    $node.SetAttribute("UseRCG", "false")
    $node.SetAttribute("UseRestrictedAdmin", "false")
    $node.SetAttribute("UserViaAPI", "")
    $node.SetAttribute("EC2InstanceId", "")
    $node.SetAttribute("EC2Region", "eu-central-1")
    $node.SetAttribute("ExternalCredentialProvider", "None")
    $node.SetAttribute("ExternalAddressProvider", "None")
    $node.SetAttribute("VaultOpenbaoMount", "")
    $node.SetAttribute("VaultOpenbaoRole", "")
    $node.SetAttribute("VaultOpenbaoSecretEngine", "Kv")

    return $node
}

function Get-MRemoteNGContainerForDomain {
    param(
        [xml]$Doc,
        [string]$Domain,
        [string]$Username = "",
        [string]$Password = ""
    )

    $root = $Doc.DocumentElement
    $existing = $root.SelectNodes("Node[@Type='Container']") | Where-Object { $_.Name -eq $Domain }
    if ($existing) {
        return $existing | Select-Object -First 1
    }

    # Create new container for this domain
    $container = New-MRemoteNGContainerNode -Doc $Doc -Name $Domain -Username $Username -Domain $Domain -Password $Password
    [void]$root.AppendChild($container)
    return $container
}

# Ensure a nested container path exists under $Parent (creating folders as
# needed) and return the innermost container. Used for the optional additive
# grouping folders (By Role\MPs, By OS\Server 2022, ...). The container Id is
# seeded from the full domain-qualified path so it never collides with the
# default role-group containers or across domains.
function Get-MRemoteNGNestedContainer {
    param(
        [xml]$Doc,
        $Parent,
        [string[]]$PathNames,
        [string]$Username = "",
        [string]$Domain = "",
        [string]$Password = "",
        [string]$SeedPrefix = "additive"
    )
    $cur = $Parent
    $seed = "$SeedPrefix`:$Domain"
    foreach ($n in $PathNames) {
        $seed = "$seed/$n"
        $child = $cur.SelectNodes("Node[@Type='Container']") | Where-Object { $_.Name -eq $n } | Select-Object -First 1
        if (-not $child) {
            $child = New-MRemoteNGContainerNode -Doc $Doc -Name $n `
                -Username $Username -Domain $Domain -Password $Password -Expanded $false
            $child.SetAttribute("Id", (Get-MRemoteNGDeterministicGuid -Seed "container:$seed"))
            [void]$cur.AppendChild($child)
        }
        $cur = $child
    }
    return $cur
}

function Add-MRemoteNGConnectionToContainer {
    param(
        [xml]$Doc,
        $Container,
        [string]$Name,
        [string]$DisplayName,
        [string]$Hostname,
        [string]$Protocol = "RDP",
        [string]$Port = "3389",
        [string]$Description = "",
        [string]$Username = "",
        [string]$Domain = "",
        [string]$Password = "",
        [string]$GuidSeed = "",
        [string]$VmId = "",
        [bool]$UseEnhancedMode = $false,
        [bool]$ForceOverwrite = $false
    )

    $id = Get-MRemoteNGDeterministicGuid -Seed $GuidSeed

    # Display names include mutable labels such as the login user. Match the
    # deterministic Id too, otherwise a rename leaves the old credential node
    # beside its replacement and the password audit repairs it on every run.
    # Do NOT match on Hostname: all Hyper-V Console entries share the host name.
    $existingNodes = @($Container.SelectNodes("Node[@Type='Connection']"))
    $matchingNodes = @($existingNodes | Where-Object {
            $_.Name -eq $DisplayName -or
            (-not [string]::IsNullOrWhiteSpace($GuidSeed) -and $_.GetAttribute("Id") -eq $id)
        })

    if ($matchingNodes.Count -gt 0 -and $ForceOverwrite) {
        foreach ($matchingNode in $matchingNodes) {
            [void]$Container.RemoveChild($matchingNode)
        }
        $matchingNodes = @()
    }

    if ($matchingNodes.Count -gt 0) {
        return $false
    }

    $node = New-MRemoteNGConnectionNode -Doc $Doc -Name $Name -DisplayName $DisplayName -Hostname $Hostname `
        -Protocol $Protocol -Port $Port -Description $Description `
        -Username $Username -Domain $Domain -Password $Password -Id $id `
        -VmId $VmId -UseEnhancedMode $UseEnhancedMode

    [void]$Container.AppendChild($node)
    Write-Log "Added $DisplayName ($Protocol) to mRemoteNG" -LogOnly
    return $true
}

function Remove-MissingConnectionsFromMRemoteNG {
    param($Container)

    $return = $false
    $completeServerList = Get-List -Type VM | Select-Object -ExpandProperty vmName
    $nodes = $Container.SelectNodes("Node[@Type='Connection']")
    foreach ($node in $nodes) {
        $hostname = $node.GetAttribute("Hostname")
        $name = $node.Name
        # Check if the VM still exists (by name or hostname)
        if ($name -in $completeServerList -or $hostname -in $completeServerList) {
            continue
        }
        # For display names with brackets, extract the VM name (first word)
        $vmNameFromDisplay = ($name -split '\s*\[')[0].Trim()
        $vmNameFromDisplay = ($vmNameFromDisplay -replace '^\[console\]\s*', '').Trim()
        if ($vmNameFromDisplay -in $completeServerList) {
            continue
        }
        Write-Log "Removing $name from mRemoteNG" -LogOnly -Verbose
        [void]$Container.RemoveChild($node)
        $return = $true
    }

    # Also check sub-containers (e.g. "Linux (SSH)")
    $subContainers = $Container.SelectNodes("Node[@Type='Container']")
    foreach ($sub in $subContainers) {
        if (Remove-MissingConnectionsFromMRemoteNG -Container $sub) {
            $return = $true
        }
        # Remove empty sub-containers
        if ($sub.SelectNodes("Node").Count -eq 0) {
            [void]$Container.RemoveChild($sub)
        }
    }

    return $return
}

function Remove-MissingDomainsFromMRemoteNG {
    param([xml]$Doc)

    $return = $false
    $domainList = Get-List -Type UniqueDomain -SmartUpdate
    $root = $Doc.DocumentElement
    $containers = $root.SelectNodes("Node[@Type='Container']")
    foreach ($container in $containers) {
        if ($container.Name -in $domainList -or $container.Name -eq "UnknownVMs") {
            continue
        }
        Write-Log "Removing domain container $($container.Name) from mRemoteNG" -LogOnly -Verbose
        [void]$root.RemoveChild($container)
        $return = $true
    }
    return $return
}

function Get-MECMSiteHierarchy {
    <#
    .SYNOPSIS
        Analyzes the VM list and returns MECM site hierarchy info for grouping.
    .DESCRIPTION
        Returns site entries ordered by rank (CAS, PRI, SEC) and a mapping
        of each MECM-related VM to its owning site code.
    #>
    param([array]$VmListFull)

    $siteServers = @($VmListFull | Where-Object { $_.Role -in "CAS", "Primary", "Secondary" })
    if ($siteServers.Count -eq 0) { return $null }

    $rankMap = @{ "CAS" = 0; "Primary" = 1; "Secondary" = 2 }
    $sites = @($siteServers | Sort-Object { $rankMap[$_.Role] }, SiteCode | ForEach-Object {
        [PSCustomObject]@{
            SiteCode       = $_.SiteCode
            Role           = $_.Role
            ParentSiteCode = $_.ParentSiteCode
            RoleLabel      = switch ($_.Role) { "CAS" { "CAS" } "Primary" { "PRI" } "Secondary" { "SEC" } }
        }
    })

    # Map each MECM VM to its owning site code
    $vmSiteMap = @{}
    foreach ($vm in $VmListFull) {
        # VMs with a direct SiteCode and an MECM role
        if ($vm.SiteCode -and $vm.Role -in "CAS", "Primary", "Secondary", "SiteSystem", "PassiveSite") {
            $vmSiteMap[$vm.vmName] = $vm.SiteCode
            continue
        }

        # WSUS with SUP belongs to its site
        if ($vm.Role -eq "WSUS" -and ($vm.installSUP -or $vm.InstallSUP) -and $vm.SiteCode) {
            $vmSiteMap[$vm.vmName] = $vm.SiteCode
            continue
        }

        # SQLAO or DomainMember with SqlVersion hosting a site DB
        if ($vm.SqlVersion -or $vm.Role -eq "SQLAO") {
            $primaryNode = $vm
            if ($vm.Role -eq "SQLAO" -and -not $vm.OtherNode) {
                $primaryNode = $VmListFull | Where-Object { $_.OtherNode -eq $vm.vmName } | Select-Object -First 1
                if (-not $primaryNode) { $primaryNode = $vm }
            }
            $siteRef = $VmListFull | Where-Object { $_.RemoteSQLVM -eq $primaryNode.vmName -and $_.Role -in "Primary", "CAS" } | Select-Object -First 1
            if ($siteRef) {
                $vmSiteMap[$vm.vmName] = $siteRef.SiteCode
                if ($vm.OtherNode) { $vmSiteMap[$vm.OtherNode] = $siteRef.SiteCode }
                continue
            }
        }

        # DomainMember with installSUP
        if ($vm.Role -eq "DomainMember" -and ($vm.installSUP -or $vm.InstallSUP) -and $vm.SiteCode) {
            $vmSiteMap[$vm.vmName] = $vm.SiteCode
            continue
        }
    }

    $label = "{" + (($sites | ForEach-Object { $_.SiteCode }) -join ", ") + "}"

    return [PSCustomObject]@{
        Sites     = $sites
        VmSiteMap = $vmSiteMap
        Label     = $label
    }
}

function Get-MECMSiteRolePriority {
    <#
    .SYNOPSIS
        Returns a numeric sort priority for a VM within its MECM site group.
        Lower values sort first (site server → passive → SQL → site systems).
    #>
    param($Vm)
    switch ($Vm.Role) {
        "CAS"          { return 0 }
        "Primary"      { return 1 }
        "Secondary"    { return 2 }
        "PassiveSite"  { return 3 }
        "SQLAO"        { return 4 }
        "SiteSystem"   { return 6 }
        "WSUS"         { return 7 }
        "DomainMember" {
            if ($Vm.SqlVersion) { return 5 }
            return 8
        }
        default        { return 9 }
    }
}

function New-MRemoteNGFileFromHyperV {
    [CmdletBinding()]
    param(
        [string]$MRemoteNGFile,
        [bool]$OverWrite = $false,
        [switch]$NoActivity,
        [switch]$WhatIf
    )

    if ($WhatIf.IsPresent) {
        Write-Log "[WhatIf] Will update mRemoteNG connection file, if needed."
        return
    }

    $Activity = -not $NoActivity.IsPresent
    Write-Log "Updating mRemoteNG connection file" -Activity:$Activity

    # ALWAYS-ON diagnostics: fingerprint the file exactly as we found it (i.e. after
    # the previous run AND after any mRemoteNG.exe edits on its last close), then
    # compare it to the fingerprint we persisted at the end of our last run. A
    # 'changed-since-last-exit: yes' with a different KdfIterations is the smoking gun
    # that mRemoteNG.exe rewrote the file (and bumped iterations) between builds,
    # which is what makes the next audit fail to decrypt every password.
    # TODO(mrng-diag): re-gate behind a switch (e.g. $global:MRNGDiag / MEMLABS_MRNG_DIAG)
    # once the root cause is confirmed and the iteration fix is in.
    $mrngDiagEntryFp = Get-MRNGFileFingerprint -Path $MRemoteNGFile
    Write-MRNGDiag ("entry fingerprint: " + (Format-MRNGFingerprint -Fingerprint $mrngDiagEntryFp))
    $mrngDiagLastExitPath = $null
    try {
        $mrngLogDir = Split-Path $Common.LogPath -Parent
        $mrngDiagLastExitPath = Join-Path $mrngLogDir "mrng-diag-last.json"
    }
    catch {}
    if ($mrngDiagLastExitPath -and (Test-Path $mrngDiagLastExitPath)) {
        try {
            $lastExit = Get-Content -Path $mrngDiagLastExitPath -Raw | ConvertFrom-Json
            $changed = $true
            if ($mrngDiagEntryFp -and $lastExit.Sha256 -and ($lastExit.Sha256 -eq $mrngDiagEntryFp.Sha256)) { $changed = $false }
            $lastKdf = $null
            if ($lastExit.RootAttrs) { $lastKdf = $lastExit.RootAttrs.KdfIterations }
            $entryKdf = $null
            if ($mrngDiagEntryFp) { $entryKdf = $mrngDiagEntryFp.RootAttrs["KdfIterations"] }
            $changedText = if ($changed) { "yes" } else { "no" }
            Write-MRNGDiag ("changed-since-last-exit: $changedText; lastExitSha256=$($lastExit.Sha256) lastExitKdfIterations=$lastKdf entryKdfIterations=$entryKdf")
        }
        catch {
            Write-MRNGDiag "could not read last-exit fingerprint: $($_.Exception.Message)"
        }
    }
    else {
        Write-MRNGDiag "no prior last-exit fingerprint found (first instrumented run)"
    }

    # Bulk-fetch all VM network adapters in one WMI call so per-VM cache
    # lookups during Get-VMFromHyperV are instant instead of ~3s each.
    Invoke-VMNetworkBulkWarmup

    # Ensure target directory exists
    $targetDir = Split-Path $MRemoteNGFile
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    # Clean up old desktop copy if it was moved to %ProgramData%
    $oldDesktopCopy = Join-Path ([Environment]::GetFolderPath("Desktop")) "memlabs-mremoteng.xml"
    if ((Test-Path $oldDesktopCopy) -and $oldDesktopCopy -ne $MRemoteNGFile) {
        Remove-Item $oldDesktopCopy -Force -ErrorAction SilentlyContinue
    }

    # Stop mRemoteNG before touching the file. If it's running it can hold a
    # file lock or save its own state mid-edit, corrupting our read or causing
    # our write to silently lose its changes.
    $killed = $false
    $mRNGProc = Get-Process -Name mRemoteNG -ErrorAction Ignore | Select-Object -First 1
    if ($mRNGProc) {
        $killed = $true
        Get-Process -Name mRemoteNG -ErrorAction Ignore | Stop-Process -Force
        Start-Sleep -Seconds 1
        Write-Log "Stopped mRemoteNG before modifying connection file." -LogOnly -Verbose
    }

    if ($OverWrite -and (Test-Path $MRemoteNGFile)) {
        Write-Log "Deleting $MRemoteNGFile and regenerating."
        Remove-Item $MRemoteNGFile -Force -ErrorAction SilentlyContinue
    }

    $shouldSave = $false

    # Load existing or create new XML
    if (Test-Path $MRemoteNGFile) {
        try {
            [xml]$doc = Get-Content -Path $MRemoteNGFile
        }
        catch {
            Write-Log "Failed to parse existing mRemoteNG file. Regenerating." -Warning
            Remove-Item $MRemoteNGFile -Force -ErrorAction SilentlyContinue
            $doc = New-MRemoteNGXmlDocument
            $shouldSave = $true
        }
    }
    else {
        $doc = New-MRemoteNGXmlDocument
        $shouldSave = $true
    }

    # Ensure root encryption attributes match our AeadCryptographyProvider defaults.
    # mRemoteNG may update KdfIterations/BlockCipherMode/etc when it saves the file.
    # We always encrypt with the provider's built-in defaults (AES-GCM, 1000 iterations),
    # so if the XML declares different parameters mRemoteNG will derive a different key
    # and every password will fail to decrypt on next load ("Decryption failed").
    # Full regen avoids this because New-MRemoteNGXmlDocument sets these attributes fresh.
    $root = $doc.DocumentElement
    $expectedRootAttrs = @{
        ConfVersion       = "2.8"
        EncryptionEngine   = "AES"
        BlockCipherMode    = "GCM"
        KdfIterations      = "1000"
        FullFileEncryption = "false"
        Protected          = "zd4H/+kOmTb3uDN3ehFiYDE5SiS79p+qWRZkMBpQjzaiU4A5rA66CcSULCGAPhxpZRrcfKy7A7NMMG4jgBSD0SPG"
    }
    foreach ($kvp in $expectedRootAttrs.GetEnumerator()) {
        if ($root.GetAttribute($kvp.Key) -ne $kvp.Value) {
            Write-Log "mRemoteNG: resetting root attribute $($kvp.Key) from '$($root.GetAttribute($kvp.Key))' to '$($kvp.Value)'" -LogOnly -Verbose
            # ALWAYS-ON diag: surface every root-attribute reset (esp. KdfIterations
            # being forced back to 1000). TODO(mrng-diag): re-gate once fixed.
            Write-MRNGDiag ("root-attr reset: $($kvp.Key) from '$($root.GetAttribute($kvp.Key))' to '$($kvp.Value)'")
            $root.SetAttribute($kvp.Key, $kvp.Value)
            $shouldSave = $true
        }
    }

    # Encrypt password
    $encryptedPass = Get-MRemoteNGPassword
    if (-not $encryptedPass) {
        $encryptedPass = ""
    }

    # Load persisted RDC settings (grouping + display-name toggles), shared with
    # the RDCMan generator so both connection files stay consistent.
    $rdcSettings = Get-RDCSettings

    # Any additive folder grouping enabled? When grouping is on but the default
    # scheme is off, VMs live ONLY in the additive folders -- not also flat under
    # the domain container (which made them show up twice).
    $anyAdditiveGrouping = [bool]($rdcSettings.AllVMsGroup -or $rdcSettings.RoleGroups -or $rdcSettings.OSGroups -or $rdcSettings.SubnetGroups -or $rdcSettings.SiteCodeGroups)

    $domainList = Get-List -Type UniqueDomain -SmartUpdate
    foreach ($domain in $domainList) {
        Write-Verbose "mRemoteNG: Processing domain $domain"

        # Get DC admin name for this domain
        $username = (Get-List -Type VM -domain $domain | Where-Object { $_.Role -eq 'DC' } | Select-Object -First 1).AdminName
        if (-not $username) {
            Write-Log "Could not determine username from DC config for domain $domain. Assuming 'admin'" -LogOnly
            $username = "admin"
        }

        $container = Get-MRemoteNGContainerForDomain -Doc $doc -Domain $domain -Username $username -Password $encryptedPass

        # Update container credentials if changed
        if ($container.GetAttribute("Username") -ne $username) {
            $container.SetAttribute("Username", $username)
            $shouldSave = $true
        }
        # Containers never hold a password (children use their own credentials).
        # Blank any leftover blob so it can't be re-flagged as corrupted next run.
        if (-not [string]::IsNullOrEmpty($container.GetAttribute("Password"))) {
            $container.SetAttribute("Password", "")
            $shouldSave = $true
        }

        # Prune removed VMs
        if (Remove-MissingConnectionsFromMRemoteNG -Container $container) {
            $shouldSave = $true
        }

        # Remove the optional additive-grouping parent containers so they are
        # rebuilt fresh from current settings (mirrors the RDCMan behavior).
        foreach ($parentName in @("All VMs", "By Role", "By OS", "By Subnet", "By Site")) {
            $existingParent = $container.SelectNodes("Node[@Type='Container']") | Where-Object { $_.Name -eq $parentName } | Select-Object -First 1
            if ($existingParent) {
                [void]$container.RemoveChild($existingParent)
                $shouldSave = $true
            }
        }

        $vmListFull = Get-List -Type VM -domain $domain

        # Determine CM version for display names
        $cmVersion = $null
        $dcVM = $vmListFull | Where-Object { $_.Role -eq 'DC' } | Select-Object -First 1
        if ($dcVM.domainDefaults.CMVersion) {
            $cmVersion = "CM" + $dcVM.domainDefaults.CMVersion
        }

        # --- Role-based group containers ---
        # Compute which groups are needed, create/find sub-containers.
        # Order defines display order in the tree.
        $groupOrder = @("MECMServers", "DomainServers", "Clients", "Servers", "Linux")
        $neededGroups = @{}
        foreach ($vm in $vmListFull) {
            if (Test-VmIsLinux -Vm $vm) {
                $neededGroups["Linux"] = $true
            }
            else {
                $grp = Get-MRemoteNGGroupForVM -Vm $vm -VmListFull $vmListFull
                $neededGroups[$grp] = $true
            }
        }

        $groupContainers = @{}
        foreach ($grpName in $groupOrder) {
            if (-not $neededGroups[$grpName]) { continue }
            # MECMServers container may have been renamed to include site codes (e.g. "MECMServers {YUM, NOM}")
            if ($grpName -eq "MECMServers") {
                $existingGrp = $container.SelectNodes("Node[@Type='Container']") | Where-Object { $_.Name -match '^MECMServers' } | Select-Object -First 1
            }
            else {
                $existingGrp = $container.SelectNodes("Node[@Type='Container']") | Where-Object { $_.Name -eq $grpName } | Select-Object -First 1
            }
            if ($existingGrp) {
                $groupContainers[$grpName] = $existingGrp
            }
            else {
                $expanded = $grpName -in @("MECMServers", "DomainServers")
                $grpNode = New-MRemoteNGContainerNode -Doc $doc -Name $grpName `
                    -Username $username -Domain $domain -Password $encryptedPass -Expanded $expanded
                [void]$container.AppendChild($grpNode)
                $groupContainers[$grpName] = $grpNode
                $shouldSave = $true
            }
        }

        # --- MECM site hierarchy sub-containers ---
        $siteHierarchy = $null
        $siteContainers = @{}
        if ($neededGroups["MECMServers"]) {
            $siteHierarchy = Get-MECMSiteHierarchy -VmListFull $vmListFull

            # Build client→siteCode map: for each client VM, determine which
            # Primary site would push the ConfigMgr client to it (network affinity).
            $clientPushSiteMap = @{}
            if ($siteHierarchy -and $siteHierarchy.Sites.Count -gt 0) {
                $primaries = $vmListFull | Where-Object { $_.Role -eq "Primary" }
                foreach ($pri in $primaries) {
                    $priNetwork = $pri.network
                    $priSiteCode = $pri.SiteCode
                    foreach ($v in $vmListFull) {
                        if ($v.network -eq $priNetwork -and -not $clientPushSiteMap.ContainsKey($v.vmName)) {
                            $clientPushSiteMap[$v.vmName] = $priSiteCode
                        }
                    }
                    $secondaries = $vmListFull | Where-Object { $_.Role -eq "Secondary" -and $_.parentSiteCode -eq $priSiteCode }
                    foreach ($sec in $secondaries) {
                        foreach ($v in $vmListFull) {
                            if ($v.network -eq $sec.network -and -not $clientPushSiteMap.ContainsKey($v.vmName)) {
                                $clientPushSiteMap[$v.vmName] = $priSiteCode
                            }
                        }
                    }
                }
            }
            if ($siteHierarchy) {
                $mecmContainer = $groupContainers["MECMServers"]

                # Update container name to show site codes
                $mecmLabel = "MECMServers $($siteHierarchy.Label)"
                if ($mecmContainer.GetAttribute("Name") -ne $mecmLabel) {
                    $mecmContainer.SetAttribute("Name", $mecmLabel)
                    $shouldSave = $true
                }

                # Migrate: remove direct connections from MECMServers container
                # (they belong in site sub-containers and will be re-added below)
                $directConns = @($mecmContainer.SelectNodes("Node[@Type='Connection']"))
                if ($directConns.Count -gt 0) {
                    foreach ($conn in $directConns) {
                        [void]$mecmContainer.RemoveChild($conn)
                    }
                    $shouldSave = $true
                }

                # Create/find site sub-containers ordered by rank (CAS, PRI, SEC)
                foreach ($site in $siteHierarchy.Sites) {
                    $siteName = "$($site.RoleLabel) ($($site.SiteCode))"
                    $existingSite = $mecmContainer.SelectNodes("Node[@Type='Container']") |
                        Where-Object { $_.Name -eq $siteName -or $_.Name -match "^$([regex]::Escape($site.RoleLabel))\s*\($([regex]::Escape($site.SiteCode))\)" } |
                        Select-Object -First 1
                    if ($existingSite) {
                        if ($existingSite.GetAttribute("Name") -ne $siteName) {
                            $existingSite.SetAttribute("Name", $siteName)
                            $shouldSave = $true
                        }
                        $siteContainers[$site.SiteCode] = $existingSite
                    }
                    else {
                        $siteNode = New-MRemoteNGContainerNode -Doc $doc -Name $siteName `
                            -Username $username -Domain $domain -Password $encryptedPass -Expanded $true
                        [void]$mecmContainer.AppendChild($siteNode)
                        $siteContainers[$site.SiteCode] = $siteNode
                        $shouldSave = $true
                    }

                    # Clear existing connections for fresh rebuild (ensures correct site placement)
                    $sc = $siteContainers[$site.SiteCode]
                    $existingConns = @($sc.SelectNodes("Node[@Type='Connection']"))
                    if ($existingConns.Count -gt 0) {
                        foreach ($econn in $existingConns) {
                            [void]$sc.RemoveChild($econn)
                        }
                        $shouldSave = $true
                    }
                }
            }
        }

        # Find or create Linux (SSH) sub-container inside the Linux group
        $linuxContainer = $null
        $linuxGroup = $groupContainers["Linux"]

        foreach ($vm in $vmListFull) {
            # --- Linux VMs: SSH entry for all, optional RDP entry ---
            if (Test-VmIsLinux -Vm $vm) {
                # SSH login account:
                #   domain-joined + domainUser -> that AD user (SSSD, NOPASSWD sudo)
                #   everything else            -> vmbuildadmin
                # vmbuildadmin is the deployment account baked into EVERY Linux
                # image with the lab password + host key, and is exactly what
                # memlabs' own SSH automation authenticates as -- so it is
                # guaranteed to exist and log in. The local 'adminName' account
                # (e.g. 'admin') is only created at first boot by cloud-init, so
                # on a VM whose first boot didn't fully complete it may be absent
                # or unusable ("account does not have access to login"); it is
                # therefore not used as the SSH target. Domain stays empty: SSSD
                # uses short names (use_fully_qualified_names=False) and mRemoteNG
                # SSH ignores the Domain field anyway. Password is the shared lab
                # password, matching the container-level vmbuildadmin default.
                $linuxJoinOn = ($vm.PSObject.Properties.Name -contains 'joinDomain') -and [bool]$vm.joinDomain
                $linuxUser = if ($linuxJoinOn -and $vm.domainUser) { $vm.domainUser } else { 'vmbuildadmin' }

                # Default-scheme SSH target:
                #   DefaultGrouping on      -> the Linux > SSH sub-container
                #   no grouping at all      -> flat under the domain container
                #   additive grouping only  -> none (SSH lives only in the folders
                #                              below, so no constant "Linux" group
                #                              is created)
                $sshDefaultTarget = $null
                if ($rdcSettings.DefaultGrouping) {
                    if (-not $linuxContainer -and $linuxGroup) {
                        $linuxContainer = $linuxGroup.SelectNodes("Node[@Type='Container']") | Where-Object { $_.Name -eq "SSH" } | Select-Object -First 1
                        if (-not $linuxContainer) {
                            $linuxContainer = New-MRemoteNGContainerNode -Doc $doc -Name "SSH" `
                                -Username "vmbuildadmin" -Domain "" -Password $encryptedPass -Protocol "SSH2" -Port "22" -Expanded $false
                            [void]$linuxGroup.AppendChild($linuxContainer)
                        }
                    }
                    $sshDefaultTarget = $linuxContainer
                }
                elseif (-not $anyAdditiveGrouping) {
                    $sshDefaultTarget = $container
                }

                # Resolve IP (same LLMNR fallback as RDCMan).
                # Prefer live IP from Hyper-V over cached LastKnownIP — DHCP
                # leases can change and LastKnownIP goes stale.
                $linuxIp = $null
                try {
                    $linuxIp = (Get-VMNetworkAdapter -VMName $vm.VmName -ErrorAction Stop).IPAddresses |
                        Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
                }
                catch { }
                if ([string]::IsNullOrWhiteSpace($linuxIp)) { $linuxIp = $vm.LastKnownIP }
                $sshHost = if (-not [string]::IsNullOrWhiteSpace($linuxIp)) { $linuxIp } else { $vm.VmName }

                $sshDisplayName = "$($vm.VmName) [Linux SSH]"
                if ($vm.SiteCode) { $sshDisplayName += " ($($vm.SiteCode))" }

                $sshComment = Format-MRemoteNGTooltip -Vm $vm -ResolvedIp $sshHost

                if ($sshDefaultTarget) {
                    if (Add-MRemoteNGConnectionToContainer -Doc $doc -Container $sshDefaultTarget `
                            -Name $vm.VmName -DisplayName $sshDisplayName -Hostname $sshHost `
                            -Protocol "SSH2" -Port "22" -Description $sshComment `
                            -Username $linuxUser -Domain "" -Password $encryptedPass `
                            -GuidSeed "ssh:${domain}:$($vm.VmName)" `
                            -ForceOverwrite $true) {
                        $shouldSave = $true
                    }
                    # Link the "Proxy Admin (Edge)" external tool to the Proxy SSH entry
                    if ($vm.Role -eq 'Proxy') {
                        $sshId = Get-MRemoteNGDeterministicGuid -Seed "ssh:${domain}:$($vm.VmName)"
                        $proxyNode = $sshDefaultTarget.SelectSingleNode("Node[@Id='$sshId']")
                        if ($proxyNode -and $proxyNode.GetAttribute("ExtApp") -ne "Proxy Admin (Edge)") {
                            $proxyNode.SetAttribute("ExtApp", "Proxy Admin (Edge)")
                            $shouldSave = $true
                        }
                    }
                }

                # Optional additive grouping folders for the SSH entry
                foreach ($fp in (Get-RDCGroupingFolders -vm $vm -settings $rdcSettings -vmListFull $vmListFull -siteHierarchy $siteHierarchy -clientPushSiteMap $clientPushSiteMap)) {
                    $addContainer = Get-MRemoteNGNestedContainer -Doc $doc -Parent $container -PathNames $fp `
                        -Username "vmbuildadmin" -Domain "" -Password $encryptedPass
                    $addSshSeed = "ssh:${domain}:$($vm.VmName):$($fp -join '/')"
                    if (Add-MRemoteNGConnectionToContainer -Doc $doc -Container $addContainer `
                            -Name $vm.VmName -DisplayName $sshDisplayName -Hostname $sshHost `
                            -Protocol "SSH2" -Port "22" -Description $sshComment `
                            -Username $linuxUser -Domain "" -Password $encryptedPass `
                            -GuidSeed $addSshSeed `
                            -ForceOverwrite $true) {
                        $shouldSave = $true
                    }
                    if ($vm.Role -eq 'Proxy') {
                        $addSshId = Get-MRemoteNGDeterministicGuid -Seed $addSshSeed
                        $addProxyNode = $addContainer.SelectSingleNode("Node[@Id='$addSshId']")
                        if ($addProxyNode -and $addProxyNode.GetAttribute("ExtApp") -ne "Proxy Admin (Edge)") {
                            $addProxyNode.SetAttribute("ExtApp", "Proxy Admin (Edge)")
                            $shouldSave = $true
                        }
                    }
                }

                # If enableRDP, also add an RDP entry. Follows the same grouping
                # rules as everything else: default Linux group when DefaultGrouping
                # is on, flat under the domain when nothing is grouped, and/or the
                # additive folders.
                $rdpOn = ($vm.PSObject.Properties.Name -contains 'enableRDP') -and [bool]$vm.enableRDP
                $isLinuxClient = $vm.Role -eq 'LinuxClient'
                if ($rdpOn -or $isLinuxClient) {
                    $rdpDisplayName = "$($vm.VmName) [Linux RDP]"
                    if ($rdcSettings.ShowUser) { $rdpDisplayName += " ($linuxUser)" }
                    if ($vm.SiteCode) { $rdpDisplayName += " ($($vm.SiteCode))" }

                    $rdpDefaultTarget = $null
                    if ($rdcSettings.DefaultGrouping) { $rdpDefaultTarget = if ($linuxGroup) { $linuxGroup } else { $container } }
                    elseif (-not $anyAdditiveGrouping) { $rdpDefaultTarget = $container }

                    if ($rdpDefaultTarget) {
                        if (Add-MRemoteNGConnectionToContainer -Doc $doc -Container $rdpDefaultTarget `
                                -Name $vm.VmName -DisplayName $rdpDisplayName -Hostname $sshHost `
                                -Protocol "RDP" -Port "3389" -Description $sshComment `
                                -Username $linuxUser -Domain "" -Password $encryptedPass `
                                -GuidSeed "rdp:${domain}:$($vm.VmName)" `
                                -ForceOverwrite $true) {
                            $shouldSave = $true
                        }
                    }

                    # Additive grouping folders for the RDP entry (parity with SSH)
                    foreach ($fp in (Get-RDCGroupingFolders -vm $vm -settings $rdcSettings -vmListFull $vmListFull -siteHierarchy $siteHierarchy -clientPushSiteMap $clientPushSiteMap)) {
                        $addRdpContainer = Get-MRemoteNGNestedContainer -Doc $doc -Parent $container -PathNames $fp `
                            -Username "vmbuildadmin" -Domain "" -Password $encryptedPass
                        if (Add-MRemoteNGConnectionToContainer -Doc $doc -Container $addRdpContainer `
                                -Name $vm.VmName -DisplayName $rdpDisplayName -Hostname $sshHost `
                                -Protocol "RDP" -Port "3389" -Description $sshComment `
                                -Username $linuxUser -Domain "" -Password $encryptedPass `
                                -GuidSeed "rdp:${domain}:$($vm.VmName):$($fp -join '/')" `
                                -ForceOverwrite $true) {
                            $shouldSave = $true
                        }
                    }
                }
                continue
            }

            # --- Windows VMs ---
            Write-Verbose "mRemoteNG: Adding VM $($vm.VmName)"

            # Determine role-based group container
            $vmGroup = Get-MRemoteNGGroupForVM -Vm $vm -VmListFull $vmListFull
            $targetContainer = $groupContainers[$vmGroup]
            if (-not $targetContainer) { $targetContainer = $container }

            # Route MECM VMs to site sub-containers
            if ($vmGroup -eq "MECMServers" -and $siteHierarchy -and $siteContainers.Count -gt 0) {
                $vmSite = $siteHierarchy.VmSiteMap[$vm.vmName]
                if ($vmSite -and $siteContainers[$vmSite]) {
                    $targetContainer = $siteContainers[$vmSite]
                }
            }

            # When the default grouping is disabled, place VMs directly under the
            # domain container (empty role-group containers are pruned at the end).
            if (-not $rdcSettings.DefaultGrouping) { $targetContainer = $container }

            $comment = Format-MRemoteNGTooltip -Vm $vm -CmVersion $cmVersion -VmListFull $vmListFull
            $name = $vm.VmName
            $ForceOverwrite = $true
            $vmID = $null

            # Build display name via shared helper (honors ShowXxx toggles)
            $displayName = Get-RDCManDisplayName -vm $vm -settings $rdcSettings -cmVersion $cmVersion -siteHierarchy $siteHierarchy -clientPushSiteMap $clientPushSiteMap

            # IP-based hostname for AAD/Internet clients
            if ($vm.Role -eq "AADClient" -or $vm.Role -eq "InternetClient") {
                if (-not [string]::IsNullOrWhiteSpace($vm.LastKnownIP)) {
                    $name = $vm.LastKnownIP
                }
                else {
                    $IP = (Get-VM2 -name $vm.vmName | Get-VMNetworkAdapter).IPAddresses | Where-Object { $_ -notlike "*:*" } | Select-Object -First 1
                    if ($IP) { $name = $IP } else { $displayName += " (Missing IP)" }
                }
            }

            if ($rdcSettings.ShowUser -and $vm.domainUser) { $displayName += " ($($vm.domainUser))" }

            # OSD/AAD clients use Hyper-V console connection
            if ($vm.Role -in ("OSDClient", "AADClient")) {
                $vmID = $vm.vmId
            }

            $connUsername = $username
            $connDomain = $domain
            $connPassword = $encryptedPass

            if (-not [string]::IsNullOrWhiteSpace($vmID)) {
                $displayName = "[console] " + $displayName
                $connUsername = $env:username
                $connDomain = ""
                $connPassword = ""
                $name = $env:computername
            }
            elseif ($vm.domainUser) {
                $connUsername = $vm.domainUser
                $connDomain = $vm.Domain
                $connPassword = $encryptedPass
            }

            # Skip the flat/default placement when additive grouping is on but the
            # default scheme is off -- the VM then lives only in the additive
            # folders below (avoids the duplicate under the domain container).
            if ($rdcSettings.DefaultGrouping -or -not $anyAdditiveGrouping) {
                if (Add-MRemoteNGConnectionToContainer -Doc $doc -Container $targetContainer `
                        -Name $name -DisplayName $displayName -Hostname $name `
                        -Protocol "RDP" -Port "3389" -Description $comment `
                        -Username $connUsername -Domain $connDomain -Password $connPassword `
                        -GuidSeed "rdp:${domain}:$($vm.VmName)" `
                        -VmId $(if ($vmID) { $vmID } else { "" }) `
                        -UseEnhancedMode $(if ($vmID) { $true } else { $false }) `
                        -ForceOverwrite $ForceOverwrite) {
                    $shouldSave = $true
                }
            }

            # Optional additive grouping folders (By Role / By OS / By Subnet / By Site / All VMs).
            # Each copy needs a distinct connection Id, so seed the GUID with the folder path.
            foreach ($fp in (Get-RDCGroupingFolders -vm $vm -settings $rdcSettings -vmListFull $vmListFull -siteHierarchy $siteHierarchy -clientPushSiteMap $clientPushSiteMap)) {
                $addContainer = Get-MRemoteNGNestedContainer -Doc $doc -Parent $container -PathNames $fp `
                    -Username $username -Domain $domain -Password $encryptedPass
                if (Add-MRemoteNGConnectionToContainer -Doc $doc -Container $addContainer `
                        -Name $name -DisplayName $displayName -Hostname $name `
                        -Protocol "RDP" -Port "3389" -Description $comment `
                        -Username $connUsername -Domain $connDomain -Password $connPassword `
                        -GuidSeed "rdp:${domain}:$($vm.VmName):$($fp -join '/')" `
                        -VmId $(if ($vmID) { $vmID } else { "" }) `
                        -UseEnhancedMode $(if ($vmID) { $true } else { $false }) `
                        -ForceOverwrite $ForceOverwrite) {
                    $shouldSave = $true
                }
            }
        }

        # --- Sort MECM site sub-containers by role priority ---
        if ($siteHierarchy -and $siteContainers.Count -gt 0) {
            foreach ($siteCode in $siteContainers.Keys) {
                $siteContainer = $siteContainers[$siteCode]
                $connections = @($siteContainer.SelectNodes("Node[@Type='Connection']"))
                if ($connections.Count -le 1) { continue }

                $sorted = @($connections | Sort-Object {
                    $hostname = $_.GetAttribute("Hostname")
                    $vm = $vmListFull | Where-Object { $_.vmName -eq $hostname } | Select-Object -First 1
                    if ($vm) { Get-MECMSiteRolePriority -Vm $vm } else { 99 }
                })

                $needsReorder = $false
                for ($i = 0; $i -lt $sorted.Count; $i++) {
                    if ($connections[$i].GetAttribute("Name") -ne $sorted[$i].GetAttribute("Name")) {
                        $needsReorder = $true
                        break
                    }
                }
                if ($needsReorder) {
                    foreach ($conn in $sorted) { [void]$siteContainer.RemoveChild($conn) }
                    foreach ($conn in $sorted) { [void]$siteContainer.AppendChild($conn) }
                    $shouldSave = $true
                }
            }
        }

        # --- Hyper-V Console sub-container ---
        # Protocol=RDP, Port=2179, UseVmId=true, Hostname=local Hyper-V host.
        # Lets users connect via Hyper-V Enhanced Session (vmconnect equivalent)
        # without needing network connectivity to the guest.
        $hvContainer = $container.SelectNodes("Node[@Type='Container']") | Where-Object { $_.Name -eq "Hyper-V Console" } | Select-Object -First 1
        if (-not $hvContainer) {
            $hvContainer = New-MRemoteNGContainerNode -Doc $doc -Name "Hyper-V Console" `
                -Username $env:USERNAME -Domain "" -Password "" -Protocol "RDP" -Port "2179" -Expanded $false
            [void]$container.AppendChild($hvContainer)
            $shouldSave = $true
        }

        foreach ($vm in $vmListFull) {
            # Explicitly stringify the Guid — a bare System.Guid flowing through
            # two [string] parameter conversions can silently become empty.
            $hvVmId = if ($vm.vmId) { "$($vm.vmId)" } else { "" }
            if ([string]::IsNullOrWhiteSpace($hvVmId)) {
                # Try to resolve from Hyper-V if not cached
                try { $hvVmId = (Get-VM -Name $vm.VmName -ErrorAction Stop).Id.ToString() } catch { }
            }
            if ([string]::IsNullOrWhiteSpace($hvVmId)) {
                Write-Log "mRemoteNG: Skipping Hyper-V Console for $($vm.VmName) — no vmId (type=$($vm.vmId.GetType().Name))" -LogOnly
                continue
            }
            Write-Log "mRemoteNG: Hyper-V Console $($vm.VmName) vmId=$hvVmId" -LogOnly

            $hvDisplayName = $vm.VmName
            if (Add-MRemoteNGConnectionToContainer -Doc $doc -Container $hvContainer `
                    -Name $vm.VmName -DisplayName $hvDisplayName -Hostname $env:COMPUTERNAME `
                    -Protocol "RDP" -Port "2179" -Description "" `
                    -Username $env:USERNAME -Domain "" -Password "" `
                    -GuidSeed "hv:${domain}:$($vm.VmName)" `
                    -VmId $hvVmId -UseEnhancedMode $true `
                    -ForceOverwrite $true) {
                $shouldSave = $true
            }
        }

        # When default grouping is disabled the role-group / MECM site containers
        # were scaffolded but left empty; prune them (also clears any empty
        # additive folders). Recursion handles nested site sub-containers.
        if (-not $rdcSettings.DefaultGrouping) {
            if (Remove-MissingConnectionsFromMRemoteNG -Container $container) {
                $shouldSave = $true
            }
        }
    }

    # Prune domains that no longer exist
    if (Remove-MissingDomainsFromMRemoteNG -Doc $doc) {
        $shouldSave = $true
    }

    # Unknown VMs (no domain)
    $unknownVMs = @()
    $unknownVMs += Get-List -type vm | Where-Object { $null -eq $_.Domain -and $null -eq $_.InProgress }
    if ($unknownVMs.Count -gt 0) {
        Write-Verbose "mRemoteNG: Adding Unknown VMs"
        $unknownContainer = Get-MRemoteNGContainerForDomain -Doc $doc -Domain "UnknownVMs" -Username "" -Password ""
        foreach ($vm in $unknownVMs) {
            $comment = Format-MRemoteNGTooltip -Vm $vm
            $displayName = $vm.VmName

            $protocol = "RDP"
            $port = "3389"
            $hostname = $vm.VmName

            if (Test-VmIsLinux -Vm $vm) {
                $protocol = "SSH2"
                $port = "22"
                $linuxIp = $vm.LastKnownIP
                if ([string]::IsNullOrWhiteSpace($linuxIp)) {
                    try {
                        $linuxIp = (Get-VMNetworkAdapter -VMName $vm.VmName -ErrorAction Stop).IPAddresses |
                            Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
                    }
                    catch { }
                }
                if (-not [string]::IsNullOrWhiteSpace($linuxIp)) { $hostname = $linuxIp }
                $displayName += " [SSH]"
            }

            if (Add-MRemoteNGConnectionToContainer -Doc $doc -Container $unknownContainer `
                    -Name $vm.VmName -DisplayName $displayName -Hostname $hostname `
                    -Protocol $protocol -Port $port -Description $comment `
                    -GuidSeed "${protocol}:unknown:$($vm.VmName)" `
                    -ForceOverwrite $false) {
                $shouldSave = $true
            }
        }
    }

    # Audit all passwords before saving — decrypt each one and verify it matches
    # the expected plaintext. Replace any corrupted passwords with a fresh value.
    if (Repair-MRemoteNGPasswords -Doc $doc -FreshEncryptedPassword $encryptedPass) {
        $shouldSave = $true
    }

    # Save
    if ($shouldSave) {
        try {

            # Use UTF-8 without BOM — mRemoteNG expects UTF-8, but [xml].Save() writes UTF-16
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            $writer = [System.IO.StreamWriter]::new($MRemoteNGFile, $false, $utf8NoBom)
            $doc.Save($writer)
            $writer.Close()
        }
        catch {
            Write-RedX "Could not update $MRemoteNGFile. $_"
        }
    }
    else {
        Write-Log "No Changes. Not updating $MRemoteNGFile" -Success -Verbose
    }

    # Full regeneration deletes the target near the start of this function. Repair
    # startup settings and links only after the replacement file exists, otherwise
    # Install-MRemoteNG skips the links and mRemoteNG can reopen a stale confCons.xml.
    Install-MRemoteNG

    # ALWAYS-ON diag: fingerprint what WE just wrote (or the unchanged file) and
    # persist it to logs\mrng-diag-last.json so the NEXT run's entry fingerprint can
    # detect whether mRemoteNG.exe rewrote the file (esp. KdfIterations) in between.
    # This persisted record is the decisive run-to-run comparison.
    # TODO(mrng-diag): re-gate once root cause is resolved.
    $mrngDiagExitFp = Get-MRNGFileFingerprint -Path $MRemoteNGFile
    Write-MRNGDiag ("script-written fingerprint (shouldSave=$shouldSave): " + (Format-MRNGFingerprint -Fingerprint $mrngDiagExitFp))
    if ($mrngDiagLastExitPath -and $mrngDiagExitFp) {
        try {
            $mrngDiagExitFp | ConvertTo-Json -Depth 5 | Out-File -FilePath $mrngDiagLastExitPath -Encoding utf8 -Force
        }
        catch {
            Write-MRNGDiag "could not persist exit fingerprint: $($_.Exception.Message)"
        }
    }

    # Restart mRemoteNG ONLY if it was actually running when we started (we stopped
    # it to edit the file). Do NOT launch it just because we saved changes ($shouldSave):
    # regenerating the connection file must not pop mRemoteNG open when the user never
    # had it running.
    if ($killed) {
        $mRNGExe = $null
        foreach ($p in @((Join-Path $env:ProgramData "memlabs\mRemoteNG\mRemoteNG.exe"), "$env:ProgramFiles\mRemoteNG\mRemoteNG.exe", "${env:ProgramFiles(x86)}\mRemoteNG\mRemoteNG.exe", "C:\ProgramData\chocolatey\lib\mremoteng\tools\mRemoteNG.exe")) {
            if (Test-Path $p) { $mRNGExe = $p; break }
        }
        if ($mRNGExe) {
            $mRNGProc = Start-Process $mRNGExe -ArgumentList "/cons:`"$MRemoteNGFile`"" -PassThru -WindowStyle Minimized -ErrorAction SilentlyContinue
            if ($mRNGProc) {
                Write-GreenCheck "Updated $MRemoteNGFile. Restarted mRemoteNG (PID $($mRNGProc.Id))" -ForegroundColor ForestGreen
                # mRemoteNG ignores -WindowStyle Minimized and restores to its saved window state.
                # Poll for its main window handle, then force-minimize repeatedly to win the race
                # against mRemoteNG's late window activation during load.
                try {
                    $swApi = Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);' -Name "SwApi" -Namespace Win32mRNG -PassThru -ErrorAction SilentlyContinue
                    $mRNGProc.WaitForInputIdle(8000) | Out-Null

                    # Poll for MainWindowHandle (may not exist until UI fully renders)
                    $hWnd = [IntPtr]::Zero
                    for ($i = 0; $i -lt 20; $i++) {
                        Start-Sleep -Milliseconds 250
                        $mRNGProc.Refresh()
                        $hWnd = $mRNGProc.MainWindowHandle
                        if ($hWnd -and $hWnd -ne [IntPtr]::Zero) {
                            $swApi::ShowWindow($hWnd, 6) | Out-Null  # SW_MINIMIZE
                            break
                        }
                    }

                    # Re-minimize after a delay: mRemoteNG often re-activates while loading connections
                    if ($hWnd -and $hWnd -ne [IntPtr]::Zero) {
                        for ($i = 0; $i -lt 4; $i++) {
                            Start-Sleep -Milliseconds 500
                            $mRNGProc.Refresh()
                            $hWnd = $mRNGProc.MainWindowHandle
                            if ($hWnd -and $hWnd -ne [IntPtr]::Zero) {
                                $swApi::ShowWindow($hWnd, 6) | Out-Null  # SW_MINIMIZE
                            }
                        }
                    }
                }
                catch {}
                Restore-TerminalFocus
            }
            else {
                Write-GreenCheck "Updated $MRemoteNGFile. mRemoteNG was stopped but failed to restart" -ForegroundColor ForestGreen
            }
        }
        elseif ($killed) {
            Write-GreenCheck "Updated $MRemoteNGFile. mRemoteNG was stopped (exe not found for restart)" -ForegroundColor ForestGreen
        }
        else {
            Write-GreenCheck "Updated $MRemoteNGFile" -ForegroundColor ForestGreen
        }
    }
    elseif ($shouldSave) {
        # File was regenerated but mRemoteNG was not running — leave it closed.
        Write-GreenCheck "Updated $MRemoteNGFile" -ForegroundColor ForestGreen
    }

    # ALWAYS-ON diag: re-read the file shortly after relaunching mRemoteNG.exe and
    # compare to the fingerprint we just wrote. mRemoteNG usually only rewrites on
    # close (so this often matches), but if it rewrites on load this catches it
    # immediately. The decisive signal remains next-run entry vs this run's persisted
    # script-written fingerprint. TODO(mrng-diag): re-gate once root cause is resolved.
    if ($killed -or $shouldSave) {
        Start-Sleep -Milliseconds 500
        $mrngDiagPostGuiFp = Get-MRNGFileFingerprint -Path $MRemoteNGFile
        Write-MRNGDiag ("post-GUI fingerprint: " + (Format-MRNGFingerprint -Fingerprint $mrngDiagPostGuiFp))
        if ($mrngDiagExitFp -and $mrngDiagPostGuiFp) {
            $postChanged = ($mrngDiagExitFp.Sha256 -ne $mrngDiagPostGuiFp.Sha256)
            $postChangedText = if ($postChanged) { "yes" } else { "no" }
            Write-MRNGDiag ("post-GUI changed-vs-script-written: $postChangedText; scriptKdf=$($mrngDiagExitFp.RootAttrs['KdfIterations']) postGuiKdf=$($mrngDiagPostGuiFp.RootAttrs['KdfIterations'])")
        }
    }

    # Ensure the "Proxy Admin" external tool is registered in extApps.xml
    Set-MRemoteNGExternalApps
}

function Set-MRemoteNGExternalApps {
    <#
    .SYNOPSIS
        Ensure mRemoteNG's extApps.xml includes a "Proxy Admin" external tool
        that opens Edge to http://%Hostname%:8443.
    .DESCRIPTION
        mRemoteNG stores external tools in %AppData%\mRemoteNG\extApps.xml.
        This function creates the file if missing, or adds the entry if absent.
        When right-clicking a Proxy SSH connection in mRemoteNG, the user can
        launch "Proxy Admin" from the External Tools menu to open the web UI.
    #>

    $extAppsDir = Join-Path $env:APPDATA 'mRemoteNG'
    $extAppsFile = Join-Path $extAppsDir 'extApps.xml'

    # Find Edge
    $edgePaths = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    )
    $edgeExe = $null
    foreach ($p in $edgePaths) {
        if (Test-Path $p) { $edgeExe = $p; break }
    }
    if (-not $edgeExe) {
        Write-Log "Edge not found; skipping mRemoteNG external tool setup" -Warning -LogOnly
        return
    }

    $toolName = "Proxy Admin (Edge)"
    $toolArgs = "http://%Hostname%:8443"

    try {
        if (Test-Path $extAppsFile) {
            [xml]$xDoc = Get-Content -Path $extAppsFile -Raw
            # Check if the tool already exists
            $existing = $xDoc.Apps.App | Where-Object { $_.DisplayName -eq $toolName }
            if ($existing) {
                # Update FileName/Arguments if they changed
                if ($existing.FileName -ne $edgeExe -or $existing.Arguments -ne $toolArgs) {
                    $existing.FileName = $edgeExe
                    $existing.Arguments = $toolArgs
                    $xDoc.Save($extAppsFile)
                    Write-Log "Updated '$toolName' external tool in extApps.xml" -LogOnly -Verbose
                }
                return
            }
        }
        else {
            # Create the directory and a new extApps.xml
            if (-not (Test-Path $extAppsDir)) {
                New-Item -ItemType Directory -Path $extAppsDir -Force | Out-Null
            }
            [xml]$xDoc = '<?xml version="1.0" encoding="utf-8"?><Apps></Apps>'
        }

        # Add the new external tool
        $appEl = $xDoc.CreateElement("App")
        $appEl.SetAttribute("DisplayName", $toolName)
        $appEl.SetAttribute("FileName", $edgeExe)
        $appEl.SetAttribute("Arguments", $toolArgs)
        $appEl.SetAttribute("WorkingDir", "")
        $appEl.SetAttribute("WaitForExit", "False")
        $appEl.SetAttribute("TryToIntegrate", "False")
        $appEl.SetAttribute("RunElevated", "False")
        $appEl.SetAttribute("ShowOnToolbar", "True")
        [void]$xDoc.DocumentElement.AppendChild($appEl)
        $xDoc.Save($extAppsFile)
        Write-Log "Added '$toolName' external tool to extApps.xml" -LogOnly -Verbose
    }
    catch {
        Write-Log "Failed to update extApps.xml: $_" -Warning -LogOnly
    }
}
