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
