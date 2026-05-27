##############################
### mRemoteNG Functions    ###
##############################

function Install-MRemoteNG {
    # Check standard install paths
    $mRemoteNGExe = $null
    $searchPaths = @(
        "${env:ProgramFiles(x86)}\mRemoteNG\mRemoteNG.exe",
        "$env:ProgramFiles\mRemoteNG\mRemoteNG.exe",
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
    if (Test-Path $shortcutPath) {
        # Verify existing shortcut has correct /cons: argument
        try {
            $shell = New-Object -ComObject WScript.Shell
            $existing = $shell.CreateShortcut($shortcutPath)
            if ($existing.Arguments -notlike "*/cons:*" -or $existing.Arguments -like "*/consfile:*") {
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
            $shortcut.Arguments = "/cons:`"$($Global:Common.MRemoteNGFilePath)`""
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
}

function Get-MRemoteNGPassword {
    # Encrypt password using mRemoteNG's BouncyCastle-based AES-GCM encryption.
    # Same pattern as Get-RDCManPassword loading rdcman.dll.
    $mRNGPath = $null
    $searchPaths = @(
        "${env:ProgramFiles(x86)}\mRemoteNG",
        "$env:ProgramFiles\mRemoteNG"
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
        $mRNGExe = Join-Path $mRNGPath "mRemoteNG.exe"

        # mRemoteNG is x86 — must use 32-bit PowerShell to load its assemblies
        $ps32 = Join-Path $env:SystemRoot "SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
        if (-not (Test-Path $ps32)) {
            Write-Log "32-bit PowerShell not found at $ps32. Cannot encrypt password." -Warning -LogOnly
            return $null
        }

        # Build a self-contained script block that runs in the 32-bit process
        $scriptText = @"
Add-Type -Path '$bouncyCastleDll' -ErrorAction Stop
[System.Reflection.Assembly]::LoadFile('$mRNGExe') | Out-Null
`$cp = New-Object mRemoteNG.Security.SymmetricEncryption.AeadCryptographyProvider
`$key = ConvertTo-SecureString 'mR3m' -AsPlainText -Force
`$cp.Encrypt('$($plaintext -replace "'","''")', `$key)
"@

        $encrypted = & $ps32 -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $scriptText 2>&1
        if ($LASTEXITCODE -ne 0 -or -not $encrypted -or $encrypted -is [System.Management.Automation.ErrorRecord]) {
            Write-Log "32-bit PowerShell encryption failed: $encrypted" -Warning -LogOnly
            return $null
        }
        return ($encrypted | Select-Object -Last 1).ToString().Trim()
    }
    catch {
        Write-Log "Failed to encrypt password via mRemoteNG assemblies: $_" -Warning -LogOnly
        return $null
    }
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
    $root.SetAttribute("ConfVersion", "2.6")

    return $doc
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
    $node.SetAttribute("Id", (Get-MRemoteNGDeterministicGuid -Seed "container:$Name"))
    $node.SetAttribute("Username", $Username)
    $node.SetAttribute("Domain", $Domain)
    $node.SetAttribute("Password", $Password)
    $node.SetAttribute("Hostname", "")
    $node.SetAttribute("Protocol", $Protocol)
    $node.SetAttribute("Port", $Port)
    $node.SetAttribute("ConnectToConsole", "false")
    $node.SetAttribute("UseCredSsp", "true")
    $node.SetAttribute("Connected", "false")

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
    $node.SetAttribute("Id", $Id)
    $node.SetAttribute("Username", $Username)
    $node.SetAttribute("Domain", $Domain)
    $node.SetAttribute("Password", $Password)
    $node.SetAttribute("Hostname", $Hostname)
    $node.SetAttribute("Protocol", $Protocol)
    $node.SetAttribute("Port", $Port)
    $node.SetAttribute("PuttySession", $PuttySession)
    $node.SetAttribute("ConnectToConsole", "false")
    $node.SetAttribute("UseCredSsp", $(if ($Protocol -eq "RDP") { "true" } else { "false" }))
    $node.SetAttribute("Connected", "false")

    if (-not [string]::IsNullOrWhiteSpace($VmId)) {
        $node.SetAttribute("VmId", $VmId)
        $node.SetAttribute("UseVmId", "true")
        $node.SetAttribute("UseEnhancedMode", $UseEnhancedMode.ToString().ToLower())
    }

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

    # Check for existing connection by display name
    $existingNodes = $Container.SelectNodes("Node[@Type='Connection']")
    $findNode = $existingNodes | Where-Object { $_.Name -eq $DisplayName -or $_.GetAttribute("Hostname") -eq $Hostname } | Select-Object -First 1

    if ($findNode -and $ForceOverwrite) {
        [void]$Container.RemoveChild($findNode)
        $findNode = $null
    }

    if ($findNode) {
        return $false
    }

    $id = Get-MRemoteNGDeterministicGuid -Seed $GuidSeed
    $node = New-MRemoteNGConnectionNode -Doc $Doc -Name $Name -DisplayName $DisplayName -Hostname $Hostname `
        -Protocol $Protocol -Port $Port -Description $Description `
        -Username $Username -Domain $Domain -Password $Password -Id $id `
        -VmId $VmId -UseEnhancedMode $UseEnhancedMode

    [void]$Container.AppendChild($node)
    Write-Log "Added $DisplayName ($Protocol) to mRemoteNG" -LogOnly -Verbose
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

    if ($OverWrite -and (Test-Path $MRemoteNGFile)) {
        Write-Log "Deleting $MRemoteNGFile and regenerating."
        Remove-Item $MRemoteNGFile -ProgressAction SilentlyContinue | Out-Null
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

    Install-MRemoteNG

    # Encrypt password
    $encryptedPass = Get-MRemoteNGPassword
    if (-not $encryptedPass) {
        $encryptedPass = ""
    }

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
        if ($encryptedPass -and $container.GetAttribute("Password") -ne $encryptedPass) {
            $container.SetAttribute("Password", $encryptedPass)
            $shouldSave = $true
        }

        # Prune removed VMs
        if (Remove-MissingConnectionsFromMRemoteNG -Container $container) {
            $shouldSave = $true
        }

        $vmListFull = Get-List -Type VM -domain $domain

        # Determine CM version for display names
        $cmVersion = $null
        $dcVM = $vmListFull | Where-Object { $_.Role -eq 'DC' } | Select-Object -First 1
        if ($dcVM.domainDefaults.CMVersion) {
            $cmVersion = "CM" + $dcVM.domainDefaults.CMVersion
        }

        # Find or create Linux (SSH) sub-container
        $linuxContainer = $null

        foreach ($vm in $vmListFull) {
            # --- Linux VMs: SSH entry for all, optional RDP entry ---
            if (Test-VmIsLinux -Vm $vm) {
                # Always create SSH entry (no enableRDP gate)
                if (-not $linuxContainer) {
                    $linuxContainer = $container.SelectNodes("Node[@Type='Container']") | Where-Object { $_.Name -eq "Linux (SSH)" } | Select-Object -First 1
                    if (-not $linuxContainer) {
                        $linuxContainer = New-MRemoteNGContainerNode -Doc $doc -Name "Linux (SSH)" `
                            -Username "vmbuildadmin" -Domain "" -Password $encryptedPass -Protocol "SSH2" -Port "22"
                        [void]$container.AppendChild($linuxContainer)
                    }
                }

                # Resolve IP (same LLMNR fallback as RDCMan)
                $linuxIp = $vm.LastKnownIP
                if ([string]::IsNullOrWhiteSpace($linuxIp)) {
                    try {
                        $linuxIp = (Get-VMNetworkAdapter -VMName $vm.VmName -ErrorAction Stop).IPAddresses |
                            Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
                    }
                    catch { }
                }
                $sshHost = if (-not [string]::IsNullOrWhiteSpace($linuxIp)) { $linuxIp } else { $vm.VmName }

                $sshDisplayName = "$($vm.VmName) [Linux SSH]"
                if ($vm.SiteCode) { $sshDisplayName += " ($($vm.SiteCode))" }

                $cSSH = [PSCustomObject]@{}
                foreach ($item in $vm | Get-Member -MemberType NoteProperty | Where-Object { $null -ne $vm."$($_.Name)" }) {
                    $cSSH | Add-Member -MemberType NoteProperty -Name $item.Name -Value $vm."$($item.Name)" -Force
                }
                $cSSH | Add-Member -MemberType NoteProperty -Name "Comment" -Value "Linux" -Force
                $sshComment = ($cSSH | ConvertTo-Json -Depth 4 -Compress)

                if (Add-MRemoteNGConnectionToContainer -Doc $doc -Container $linuxContainer `
                        -Name $vm.VmName -DisplayName $sshDisplayName -Hostname $sshHost `
                        -Protocol "SSH2" -Port "22" -Description $sshComment `
                        -Username "vmbuildadmin" -Domain "" -Password $encryptedPass `
                        -GuidSeed "ssh:${domain}:$($vm.VmName)" `
                        -ForceOverwrite $true) {
                    $shouldSave = $true
                }

                # If enableRDP, also add an RDP entry in the main container
                $rdpOn = ($vm.PSObject.Properties.Name -contains 'enableRDP') -and [bool]$vm.enableRDP
                $isLinuxClient = $vm.Role -eq 'LinuxClient'
                if ($rdpOn -or $isLinuxClient) {
                    $rdpDisplayName = "$($vm.VmName) [Linux RDP] (vmbuildadmin)"
                    if ($vm.SiteCode) { $rdpDisplayName += " ($($vm.SiteCode))" }

                    if (Add-MRemoteNGConnectionToContainer -Doc $doc -Container $container `
                            -Name $vm.VmName -DisplayName $rdpDisplayName -Hostname $sshHost `
                            -Protocol "RDP" -Port "3389" -Description $sshComment `
                            -Username "vmbuildadmin" -Domain "" -Password $encryptedPass `
                            -GuidSeed "rdp:${domain}:$($vm.VmName)" `
                            -ForceOverwrite $true) {
                        $shouldSave = $true
                    }
                }
                continue
            }

            # --- Windows VMs ---
            Write-Verbose "mRemoteNG: Adding VM $($vm.VmName)"

            $c = [PSCustomObject]@{}
            foreach ($item in $vm | Get-Member -MemberType NoteProperty | Where-Object { $null -ne $vm."$($_.Name)" }) {
                $c | Add-Member -MemberType NoteProperty -Name $item.Name -Value $vm."$($item.Name)" -Force
            }

            # Set Comment property for description (mirrors RDCMan logic)
            if ($vm.Role -eq "DomainMember" -or $vm.Role -eq "WorkgroupMember") {
                $deployedOS = $vm.deployedOS
                $isServer = $deployedOS -match "Server"
                if ($null -eq $vm.SqlVersion -and $isServer) {
                    if ($vm.InstallCA) {
                        $c | Add-Member -MemberType NoteProperty -Name "Comment" -Value "IssuingCA" -Force
                    }
                    else {
                        $c | Add-Member -MemberType NoteProperty -Name "Comment" -Value "PlainMemberServer" -Force
                    }
                }
                elseif (-not $isServer) {
                    $c | Add-Member -MemberType NoteProperty -Name "Comment" -Value "PlainMemberClient" -Force
                }
            }
            if ($vm.Role -eq "WSUS") {
                if ($vm.installSUP) {
                    $c | Add-Member -MemberType NoteProperty -Name "SUPForSiteServer" -Value "$($vm.SiteCode)" -Force
                }
                else {
                    $c | Add-Member -MemberType NoteProperty -Name "Comment" -Value "PlainMemberServer" -Force
                }
            }
            if ($vm.SqlVersion) {
                $PrimaryNode = $vm
                if ($vm.role -eq "SQLAO") {
                    if (-not $vm.OtherNode) {
                        $primaryNode = $vmListFull | Where-Object { $_.OtherNode -eq $vm.vmName }
                    }
                }
                $SiteServer = $vmListFull | Where-Object { $_.RemoteSQLVM -eq $PrimaryNode.vmName -and $_.Role -in "Primary", "CAS" }
                if ($SiteServer) {
                    $c | Add-Member -MemberType NoteProperty -Name "SQLForSiteServer" -Value "$($SiteServer.SiteCode)" -Force
                }
                elseif ($vm.Role -eq "DomainMember") {
                    $c | Add-Member -MemberType NoteProperty -Name "Comment" -Value "PlainMemberServer" -Force
                }
            }

            $comment = $c | ConvertTo-Json
            $name = $vm.VmName
            $ForceOverwrite = $true
            $vmID = $null

            # Build display name (same bracket-tag logic as RDCMan)
            $roleTag = $null
            switch ($vm.Role) {
                "DC"               { $roleTag = "DC" }
                "BDC"              { $roleTag = "BDC" }
                "CAS"              { $roleTag = "CAS" }
                "Primary"          { $roleTag = "PRI" }
                "Secondary"        { $roleTag = "SEC" }
                "PassiveSite"      { $roleTag = "Passive" }
                "SQLAO"            { $roleTag = "SQLAO" }
                "WSUS"             { $roleTag = "WSUS" }
                "FileServer"       { $roleTag = "FS" }
                "OSDClient"        { $roleTag = "OSD" }
                "StandaloneRootCA" { $roleTag = "RootCA" }
                "InternetClient"   { $roleTag = "Internet" }
                "AADClient"        { $roleTag = "AAD" }
                "WorkgroupMember"  { $roleTag = "WG" }
                Default { }
            }

            $siteRolesTag = $null
            if ($vm.Role -eq "SiteSystem") {
                $sr = @()
                if ($vm.installMP) { $sr += "MP" }
                if ($vm.installDP) { $sr += "DP" }
                if ($vm.installSUP -or $vm.InstallSUP) { $sr += "SUP" }
                if ($vm.InstallRP) { $sr += "RP" }
                if ($vm.InstallSMSProv) { $sr += "SMSProv" }
                if ($sr.Count -gt 0) { $siteRolesTag = $sr -join ',' }
            }

            $caTag = $null
            if ($vm.InstallCA -and $vm.Role -ne "StandaloneRootCA") { $caTag = "CA" }

            $supTag = $null
            if (($vm.installSUP -or $vm.InstallSUP) -and $vm.Role -ne "SiteSystem") { $supTag = "WSUS" }

            $proxyTag = $null
            if ($vm.useProxy) { $proxyTag = "Proxy" }

            if ($roleTag -and $vm.VmName -match [regex]::Escape($roleTag)) { $roleTag = $null }

            $tagParts = @()
            if ($roleTag) { $tagParts += $roleTag }
            if ($caTag) { $tagParts += $caTag }
            if ($supTag) { $tagParts += $supTag }
            if ($proxyTag) { $tagParts += $proxyTag }

            $osShort = Get-RDCManOSShortName -deployedOS $vm.deployedOS
            if ($osShort -and -not ($vm.VmName -match [regex]::Escape($osShort))) { $tagParts += $osShort }

            if ($cmVersion -and $vm.Role -in "CAS", "Primary", "Secondary", "SiteSystem", "PassiveSite") {
                $tagParts += $cmVersion
            }
            if ($siteRolesTag) { $tagParts += $siteRolesTag }

            $displayName = $vm.VmName
            if ($tagParts.Count -gt 0) { $displayName += " [$($tagParts -join ' ')]" }
            if ($vm.SiteCode) {
                $displayName += " ($($vm.SiteCode)"
                if ($vm.ParentSiteCode) { $displayName += "->$($vm.ParentSiteCode)" }
                $displayName += ")"
            }

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

            if ($vm.domainUser) { $displayName += " ($($vm.domainUser))" }

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

            if (Add-MRemoteNGConnectionToContainer -Doc $doc -Container $container `
                    -Name $name -DisplayName $displayName -Hostname $name `
                    -Protocol "RDP" -Port "3389" -Description $comment.ToString() `
                    -Username $connUsername -Domain $connDomain -Password $connPassword `
                    -GuidSeed "rdp:${domain}:$($vm.VmName)" `
                    -VmId $(if ($vmID) { $vmID } else { "" }) `
                    -UseEnhancedMode $(if ($vmID) { $true } else { $false }) `
                    -ForceOverwrite $ForceOverwrite) {
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
            $c = [PSCustomObject]@{}
            foreach ($item in $vm | Get-Member -MemberType NoteProperty | Where-Object { $null -ne $vm."$($_.Name)" }) {
                $c | Add-Member -MemberType NoteProperty -Name $item.Name -Value $vm."$($item.Name)" -Force
            }
            $comment = $c | ConvertTo-Json
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
                    -Protocol $protocol -Port $port -Description $comment.ToString() `
                    -GuidSeed "${protocol}:unknown:$($vm.VmName)" `
                    -ForceOverwrite $false) {
                $shouldSave = $true
            }
        }
    }

    # Save
    if ($shouldSave) {
        try {
            $doc.Save($MRemoteNGFile) | Out-Null
            Write-GreenCheck "Updated $MRemoteNGFile" -ForegroundColor ForestGreen
        }
        catch {
            Write-RedX "Could not update $MRemoteNGFile. $_"
        }
    }
    else {
        Write-Log "No Changes. Not updating $MRemoteNGFile" -Success -Verbose
    }
}
