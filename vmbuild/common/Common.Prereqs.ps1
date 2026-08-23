# Keep this file ASCII-only. createGuestDscZip.ps1 dot-sources it under PS 5.1, which reads a
# BOM-less .ps1 as Windows-1252 and mis-parses any multi-byte UTF-8 character.
#
# Common.Prereqs.ps1
# Host-side prerequisite bootstrap. These run on a freshly built lab host where nothing
# beyond stock Windows is present.
#
# Exports:
#   Test-MemLabsElevated     - is this session running as Administrator
#   Initialize-PSGallery     - TLS 1.2 + NuGet provider + registered/trusted PSGallery, so
#                              Install-Module cannot stop on an interactive prompt
#   Install-MemLabsModule    - install/update PSGallery modules and VERIFY they landed
#   Get-OpenSshToolPath      - locate ssh.exe / ssh-keygen.exe, installing the Windows
#                              OpenSSH Client capability when it is missing

function Test-MemLabsElevated {
    return ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-PrereqLog {
    param (
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Failure')][string]$Level = 'Info'
    )

    # createGuestDscZip.ps1 loads this file before Common.ps1, so Write-Log may not exist yet.
    if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
        switch ($Level) {
            'Success' { Write-Log $Message -Success }
            'Warning' { Write-Log $Message -Warning }
            'Failure' { Write-Log $Message -Failure }
            default { Write-Log $Message }
        }
        return
    }

    switch ($Level) {
        'Success' { Write-Host $Message -ForegroundColor Green }
        'Warning' { Write-Host $Message -ForegroundColor Yellow }
        'Failure' { Write-Host $Message -ForegroundColor Red }
        default { Write-Host $Message }
    }
}

function Get-MemLabsBuildServerMarkerPath {
    # Mirrors Get-MemlabsDataRoot in Common.StorageToken.ps1, which is not loaded yet when the
    # DSC build scripts run this gate. Deliberately outside the repo so a git pull or a fresh
    # clone never carries the designation to another host.
    $root = $env:MEMLABS_DATA_ROOT
    if ([string]::IsNullOrWhiteSpace($root)) {
        $programData = $env:ProgramData
        if ([string]::IsNullOrWhiteSpace($programData)) { $programData = 'C:\ProgramData' }
        $root = Join-Path $programData 'memlabs'
    }
    return (Join-Path $root 'dsc-build-server.json')
}

function Test-MemLabsBuildServer {
    <#
    .SYNOPSIS
        Is this host designated to BUILD DSC.zip / Host.zip?

    .DESCRIPTION
        Building rewrites DSC.zip and version.json in the repo and installs 15 DSC modules
        machine-wide. Lab hosts consume those artifacts and must never produce them, so the
        build scripts refuse to run unless this host was explicitly designated.
    #>
    [CmdletBinding()]
    param ()

    $path = Get-MemLabsBuildServerMarkerPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }

    $marker = $null
    try { $marker = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch {
        Write-PrereqLog "Build-server marker $path is unreadable: $_" -Level Warning
        return $false
    }

    # Lab hosts come off a shared Azure image; a marker baked into that image would silently
    # promote every host, so the designation only counts for the machine it names.
    if ($marker.ComputerName -ne $env:COMPUTERNAME) {
        Write-PrereqLog "Build-server marker names '$($marker.ComputerName)' but this host is '$env:COMPUTERNAME'; ignoring it." -Level Warning
        return $false
    }
    return $true
}

function Set-MemLabsBuildServer {
    <#
    .SYNOPSIS
        Designate (or, with -Remove, undesignate) this host as a MemLabs DSC build server.
    #>
    [CmdletBinding()]
    param (
        [switch]$Remove
    )

    $path = Get-MemLabsBuildServerMarkerPath

    if ($Remove) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
        Write-PrereqLog "$env:COMPUTERNAME is no longer a MemLabs DSC build server (removed $path)." -Level Success
        return
    }

    $root = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop | Out-Null
    }
    [pscustomobject]@{
        ComputerName  = $env:COMPUTERNAME
        DesignatedBy  = "$env:USERDOMAIN\$env:USERNAME"
        DesignatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json | Out-File -LiteralPath $path -Force -Encoding utf8 -ErrorAction Stop
    Write-PrereqLog "$env:COMPUTERNAME is now a MemLabs DSC build server (wrote $path)." -Level Success
}

function Deny-MemLabsNonBuildServer {
    <#
    .SYNOPSIS
        Print why the build was refused and how to designate this host. Callers return after.
    #>
    param (
        [Parameter(Mandatory = $true)][string]$ScriptName
    )

    Write-Host
    Write-Host "$ScriptName refused to run: $env:COMPUTERNAME is not a designated MemLabs DSC build server." -ForegroundColor Red
    Write-Host "Building rewrites DSC.zip/version.json in the repo and installs DSC modules machine-wide," -ForegroundColor Yellow
    Write-Host "which is not something a lab host should ever do." -ForegroundColor Yellow
    Write-Host
    Write-Host "If this IS the build server, designate it once (elevated):" -ForegroundColor Cyan
    Write-Host "    .\$ScriptName -DesignateBuildServer" -ForegroundColor Cyan
    Write-Host "Marker file: $(Get-MemLabsBuildServerMarkerPath)" -ForegroundColor Cyan
    Write-Host
}

function Initialize-PSGallery {
    <#
    .SYNOPSIS
        Make Install-Module usable and non-interactive on a machine that has never used it.

    .DESCRIPTION
        Three stock-Windows defaults each turn Install-Module into a silent stall rather than
        an error: TLS 1.0/1.1 negotiation that PSGallery refuses, a missing NuGet provider
        ("NuGet provider is required to continue" prompt), and an untrusted PSGallery
        ("Are you sure you want to install..." prompt). Returns $false if the gallery still
        is not usable, so the caller can fail instead of running into the prompt.
    #>
    [CmdletBinding()]
    param (
        [switch]$Force
    )

    if ($script:MemLabsPSGalleryReady -and -not $Force) { return $true }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {
        Write-PrereqLog "Could not enable TLS 1.2 for this session: $_" -Level Warning
    }

    try { Import-Module PackageManagement, PowerShellGet -ErrorAction SilentlyContinue -Verbose:$false }
    catch { Write-PrereqLog "Import of PackageManagement/PowerShellGet failed: $_" -Level Warning }

    $scope = 'CurrentUser'
    if (Test-MemLabsElevated) { $scope = 'AllUsers' }

    $nuget = $null
    try {
        $nuget = @(Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending) | Select-Object -First 1
    }
    catch { }

    if (-not $nuget -or $nuget.Version -lt [Version]'2.8.5.201') {
        Write-PrereqLog "Installing the NuGet package provider (Install-Module prompts for it otherwise)..."
        try {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope $scope -ErrorAction Stop -Verbose:$false | Out-Null
            Import-Module PackageManagement -Force -ErrorAction SilentlyContinue -Verbose:$false
        }
        catch {
            Write-PrereqLog "Failed to install the NuGet package provider: $_" -Level Failure
            return $false
        }
    }

    $repo = $null
    try { $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue } catch { }
    if (-not $repo) {
        try { Register-PSRepository -Default -ErrorAction Stop }
        catch { Write-PrereqLog "Register-PSRepository -Default failed: $_" -Level Warning }
        try { $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue } catch { }
    }
    if (-not $repo) {
        Write-PrereqLog "PSGallery is not registered and could not be re-registered; modules cannot be installed." -Level Failure
        return $false
    }
    if ($repo.InstallationPolicy -ne 'Trusted') {
        try { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop }
        catch { Write-PrereqLog "Could not mark PSGallery trusted: $_" -Level Warning }
    }

    $script:MemLabsPSGalleryReady = $true
    return $true
}

function Get-MemLabsModuleInstallPath {
    param (
        [Parameter(Mandatory = $true)][ValidateSet('AllUsers', 'CurrentUser')][string]$Scope
    )

    # PS 5.1 and PS 7 have separate module roots; createGuestDscZip.ps1 runs under 5.1 and its
    # Start-Job child must see the same modules, so this has to follow the current edition.
    $leaf = 'WindowsPowerShell'
    if ($PSVersionTable.PSEdition -eq 'Core') { $leaf = 'PowerShell' }

    if ($Scope -eq 'AllUsers') {
        return (Join-Path (Join-Path $env:ProgramFiles $leaf) 'Modules')
    }
    return (Join-Path (Join-Path ([Environment]::GetFolderPath('MyDocuments')) $leaf) 'Modules')
}

function Clear-PackageManagementCache {
    <#
    .SYNOPSIS
        Drop cached .nupkg files for a module.

    .DESCRIPTION
        A truncated download is cached and re-used, so Install-Module keeps failing with
        "End of Central Directory record could not be found" on every retry until the bad
        zip is deleted.
    #>
    param (
        [Parameter(Mandatory = $true)][string]$Name
    )

    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'PackageManagement\NuGet\Packages'),
        (Join-Path $env:ProgramData 'PackageManagement\NuGet\Packages'),
        $env:TEMP
    )
    $removed = 0
    foreach ($root in $roots) {
        if (-not $root -or -not (Test-Path $root -PathType Container)) { continue }
        $stale = @(Get-ChildItem -Path $root -Filter "$Name*" -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.PSIsContainer -or $_.Extension -eq '.nupkg' })
        foreach ($item in $stale) {
            try { Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop; $removed++ }
            catch { }
        }
    }
    if ($removed -gt 0) { Write-PrereqLog "Cleared $removed cached package item(s) for $Name." }
    return $removed
}

function Install-ModuleFromNupkg {
    <#
    .SYNOPSIS
        Install a PSGallery module by downloading and expanding its .nupkg directly.

    .DESCRIPTION
        Last resort when PackageManagement itself is the problem. The download is validated
        as a real zip BEFORE expansion, which is the exact check Install-Module fails on, so
        a truncated transfer is retried instead of being installed as a broken module.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('AllUsers', 'CurrentUser')][string]$Scope
    )

    $work = Join-Path $env:TEMP ('memlabs-nupkg-' + [guid]::NewGuid().ToString('N'))
    $extractDir = Join-Path $work 'x'
    $nupkg = Join-Path $work "$Name.zip"
    $oldProgress = $Global:ProgressPreference
    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $Global:ProgressPreference = 'SilentlyContinue'

        if (-not ('System.IO.Compression.ZipFile' -as [type])) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        }

        $url = "https://www.powershellgallery.com/api/v2/package/$Name"
        $valid = $false
        for ($attempt = 1; $attempt -le 3 -and -not $valid; $attempt++) {
            if (Test-Path -LiteralPath $nupkg) { Remove-Item -LiteralPath $nupkg -Force -ErrorAction SilentlyContinue }
            try {
                Invoke-WebRequest -Uri $url -OutFile $nupkg -UseBasicParsing -ErrorAction Stop
            }
            catch {
                # PS 7 folds the whole HTTP response body into the message; collapse it or
                # the log fills with blank lines from the gallery's error page.
                $msg = ($_.Exception.Message -replace '\s+', ' ').Trim()
                if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + '...' }
                Write-PrereqLog "Download of $Name (attempt $attempt) failed: $msg" -Level Warning
                if ($msg -match '404') { break }
                continue
            }

            try {
                $zip = [System.IO.Compression.ZipFile]::OpenRead($nupkg)
                try { $valid = ($zip.Entries.Count -gt 0) } finally { $zip.Dispose() }
                if (-not $valid) { Write-PrereqLog "Downloaded $Name package is an empty zip (attempt $attempt)." -Level Warning }
            }
            catch {
                $sizeKb = 0
                if (Test-Path -LiteralPath $nupkg) { $sizeKb = [math]::Round((Get-Item -LiteralPath $nupkg).Length / 1KB, 1) }
                Write-PrereqLog "Downloaded $Name package is not a valid zip (attempt $attempt, ${sizeKb}KB): $_" -Level Warning
            }
        }
        if (-not $valid) { return $false }

        Expand-Archive -LiteralPath $nupkg -DestinationPath $extractDir -Force -ErrorAction Stop

        $version = $null
        $psd1 = Join-Path $extractDir "$Name.psd1"
        if (Test-Path -LiteralPath $psd1) {
            try { $version = (Import-PowerShellDataFile -LiteralPath $psd1).ModuleVersion } catch { }
        }
        if (-not $version) {
            $nuspec = @(Get-ChildItem -LiteralPath $extractDir -Filter '*.nuspec' -File -ErrorAction SilentlyContinue) | Select-Object -First 1
            if ($nuspec) {
                try {
                    $xml = [xml](Get-Content -LiteralPath $nuspec.FullName -Raw)
                    $version = ($xml.package.metadata.version -split '-')[0]
                }
                catch { }
            }
        }
        if (-not $version) {
            Write-PrereqLog "Could not determine a version for $Name from the downloaded package." -Level Warning
            return $false
        }

        # NuGet packaging artifacts; brackets in the path make -LiteralPath mandatory.
        foreach ($junk in @('_rels', 'package', '[Content_Types].xml')) {
            $junkPath = Join-Path $extractDir $junk
            if (Test-Path -LiteralPath $junkPath) { Remove-Item -LiteralPath $junkPath -Recurse -Force -ErrorAction SilentlyContinue }
        }
        Get-ChildItem -LiteralPath $extractDir -Filter '*.nuspec' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

        $target = Join-Path (Join-Path (Get-MemLabsModuleInstallPath -Scope $Scope) $Name) $version
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop }
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Get-ChildItem -LiteralPath $extractDir -Force | Copy-Item -Destination $target -Recurse -Force -ErrorAction Stop
        Get-ChildItem -LiteralPath $target -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

        Write-PrereqLog "Installed $Name $version from nupkg to $target" -Level Success
        return $true
    }
    catch {
        Write-PrereqLog "Direct nupkg install of $Name failed: $_" -Level Warning
        return $false
    }
    finally {
        $Global:ProgressPreference = $oldProgress
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Install-MemLabsModule {
    <#
    .SYNOPSIS
        Install the named PSGallery modules if they are missing, and report what is STILL
        missing afterwards.

    .DESCRIPTION
        Install-Module can report success and leave nothing on disk (partial download, a
        provider that fell back to a stale cache). The caller only finds out much later, in
        an unreadable Publish-AzVMDscConfiguration or DSC compile error, so every install is
        re-probed here and anything that did not land comes back in .Failed.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string[]]$Name,
        [switch]$Update
    )

    $available = @(Get-Module -ListAvailable -Verbose:$false | Select-Object -ExpandProperty Name) | Sort-Object -Unique
    $present = @($Name | Where-Object { $available -contains $_ })
    $missing = @($Name | Where-Object { $available -notcontains $_ })

    if ($missing.Count -gt 0 -or ($Update -and $present.Count -gt 0)) {
        if (-not (Initialize-PSGallery)) {
            return [pscustomobject]@{ Present = $present; Installed = @(); Updated = @(); Failed = $missing }
        }
    }

    $scope = 'CurrentUser'
    if (Test-MemLabsElevated) { $scope = 'AllUsers' }

    $installed = @()
    $failed = @()
    foreach ($module in $missing) {
        Write-PrereqLog "Installing module: $module (scope $scope)"
        try {
            Install-Module -Name $module -Force -Confirm:$false -Scope $scope -AllowClobber -SkipPublisherCheck -ErrorAction Stop -Verbose:$false
        }
        catch {
            Write-PrereqLog "Install-Module $module failed: $_" -Level Warning

            # A bad .nupkg is CACHED, so a plain retry replays the same corrupt zip
            # ("End of Central Directory record could not be found") forever.
            $clearedCount = Clear-PackageManagementCache -Name $module
            if ($clearedCount -gt 0) {
                Write-PrereqLog "Retrying Install-Module $module after clearing the package cache..."
                try { Install-Module -Name $module -Force -Confirm:$false -Scope $scope -AllowClobber -SkipPublisherCheck -ErrorAction Stop -Verbose:$false }
                catch { Write-PrereqLog "Retry of Install-Module $module failed: $_" -Level Warning }
            }

            if (-not (Get-Module -ListAvailable -Name $module -Verbose:$false)) {
                Write-PrereqLog "Falling back to a direct PSGallery nupkg download for $module..." -Level Warning
                $null = Install-ModuleFromNupkg -Name $module -Scope $scope
            }
        }

        if (Get-Module -ListAvailable -Name $module -Verbose:$false) { $installed += $module }
        else { $failed += $module }
    }

    $updated = @()
    if ($Update) {
        foreach ($module in $present) {
            Write-PrereqLog "Updating module: $module"
            try {
                Update-Module -Name $module -Force -Confirm:$false -ErrorAction Stop -Verbose:$false
                $updated += $module
            }
            catch {
                # A failed update leaves the working version in place, so this is not fatal.
                Write-PrereqLog "Update-Module $module failed; keeping the installed version: $_" -Level Warning
            }
        }
    }

    return [pscustomobject]@{
        Present   = $present
        Installed = $installed
        Updated   = $updated
        Failed    = $failed
    }
}

function Find-OpenSshTool {
    param (
        [Parameter(Mandatory = $true)][string]$Name
    )

    $cmd = @(Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue)
    if ($cmd.Count -gt 0) { return $cmd[0].Source }
    $inbox = Join-Path $env:WINDIR "System32\OpenSSH\$Name"
    if (Test-Path $inbox -PathType Leaf) { return $inbox }
    return $null
}

function Install-OpenSshClientFeature {
    <#
    .SYNOPSIS
        Add the Windows OpenSSH Client capability (ssh.exe, ssh-keygen.exe, scp.exe).
    #>
    [CmdletBinding()]
    param ()

    # Checked before the mutex: a filtered (non-elevated) admin token lacks
    # SeCreateGlobalPrivilege, so creating a Global\ mutex would throw here instead of
    # reaching the message that says what is actually wrong.
    if (-not (Test-MemLabsElevated)) {
        Write-PrereqLog "OpenSSH Client is missing and this session is not elevated, so it cannot be installed. Re-run as Administrator." -Level Failure
        return $false
    }

    # Phase 1 creates every Linux VM in parallel and each job can land here; two concurrent
    # Add-WindowsCapability calls against the same online image fail with a servicing error.
    $mutex = [System.Threading.Mutex]::new($false, 'Global\MemlabsOpenSshInstallLock')
    $held = $false
    try {
        try { $held = $mutex.WaitOne([TimeSpan]::FromMinutes(10)) }
        catch [System.Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) {
            Write-PrereqLog "Timed out waiting for the OpenSSH client install lock." -Level Failure
            return $false
        }

        # Another job may have installed it while we waited on the mutex.
        if (Find-OpenSshTool -Name 'ssh.exe') { return $true }

        $capability = $null
        try {
            $capability = @(Get-WindowsCapability -Online -Name 'OpenSSH.Client*' -ErrorAction Stop) | Select-Object -First 1
        }
        catch {
            Write-PrereqLog "Get-WindowsCapability could not enumerate OpenSSH.Client: $_" -Level Warning
        }

        if ($capability) {
            Write-PrereqLog "Installing Windows capability $($capability.Name)..."
            try { Add-WindowsCapability -Online -Name $capability.Name -ErrorAction Stop | Out-Null }
            catch { Write-PrereqLog "Add-WindowsCapability failed: $_" -Level Warning }
        }
        else {
            Write-PrereqLog "Falling back to dism.exe for OpenSSH.Client..." -Level Warning
            $dism = Join-Path $env:WINDIR 'System32\dism.exe'
            if (Test-Path $dism -PathType Leaf) {
                # Under $ErrorActionPreference = 'Stop' a native stderr line throws before
                # $LASTEXITCODE can be read, which would skip the reporting below.
                $savedEap = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    & $dism /online /add-capability /capabilityname:OpenSSH.Client~~~~0.0.1.0 /quiet /norestart 2>&1 | Out-Null
                    $dismExit = $LASTEXITCODE
                    if ($dismExit -ne 0 -and $dismExit -ne 3010) {
                        Write-PrereqLog "dism /add-capability exited with $dismExit." -Level Warning
                    }
                }
                finally { $ErrorActionPreference = $savedEap }
            }
        }

        $resolved = Find-OpenSshTool -Name 'ssh.exe'
        if ($resolved) {
            Write-PrereqLog "OpenSSH Client installed: $resolved" -Level Success
            return $true
        }

        Write-PrereqLog "OpenSSH Client install completed but ssh.exe is still not present." -Level Failure
        return $false
    }
    finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-OpenSshToolPath {
    <#
    .SYNOPSIS
        Return the full path to an OpenSSH client tool, installing the capability on demand.
        Returns $null when it is missing and could not be installed.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][ValidateSet('ssh.exe', 'ssh-keygen.exe', 'scp.exe')][string]$Name
    )

    $found = Find-OpenSshTool -Name $Name
    if ($found) { return $found }

    Write-PrereqLog "$Name not found; installing the Windows OpenSSH Client capability..." -Level Warning
    if (Install-OpenSshClientFeature) {
        return (Find-OpenSshTool -Name $Name)
    }
    return $null
}
