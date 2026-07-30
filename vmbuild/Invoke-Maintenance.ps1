[CmdletBinding()]
param ()

$ErrorActionPreference = 'Continue'

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$logsPath = Join-Path $scriptPath 'logs'
$logFile = Join-Path $logsPath "Maintenance_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

if (-not (Test-Path $logsPath)) {
    New-Item -ItemType Directory -Path $logsPath -Force | Out-Null
}

# Clean up old maintenance logs (keep only the 3 most recent)
$maintenanceLogs = Get-ChildItem -Path $logsPath -Filter 'Maintenance_*.log' -ErrorAction SilentlyContinue | Sort-Object -Property CreationTime -Descending
if ($maintenanceLogs.Count -gt 3) {
    $logsToDelete = $maintenanceLogs | Select-Object -Skip 3
    foreach ($logToDelete in $logsToDelete) {
        Remove-Item -Path $logToDelete.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Write-LogMessage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('INFO', 'WARNING', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] $Message"

    Write-Host $logEntry
    Add-Content -Path $logFile -Value $logEntry -ErrorAction SilentlyContinue
}

function Test-ChocoSuccessCode {
    param (
        [int]$Code
    )

    return ($Code -eq 0 -or $Code -eq 1641 -or $Code -eq 3010)
}

function Test-ChocoAvailable {
    return ($null -ne (Get-Command choco -ErrorAction SilentlyContinue))
}

$script:MaintenanceHadFailure = $false

function Invoke-System32CurlMaintenance {
    Write-LogMessage 'Starting System32 curl maintenance...'

    $system32Curl = Join-Path $env:WINDIR 'System32\curl.exe'
    $chocoCurlShim = 'C:\ProgramData\chocolatey\bin\curl.exe'

    if (-not (Test-Path $system32Curl)) {
        Write-LogMessage 'System32 curl not found. Skipping curl maintenance.'
        return
    }

    Write-LogMessage "System32 curl detected at '$system32Curl'."

    if (-not (Test-Path $chocoCurlShim)) {
        Write-LogMessage "Chocolatey curl shim not found at '$chocoCurlShim'. Skipping uninstall."
        return
    }

    if (-not (Test-ChocoAvailable)) {
        Write-LogMessage 'Chocolatey CLI not found. Skipping curl uninstall.' -Level 'WARNING'
        return
    }

    Write-LogMessage 'Removing Chocolatey curl package to avoid non-System32 curl usage...'
    & choco uninstall curl -y | Out-Null
    $exitCode = $LASTEXITCODE
    Write-LogMessage "choco uninstall curl returned exit code: $exitCode"

    if ($exitCode -ne 0) {
        Write-LogMessage 'First curl uninstall attempt failed. Retrying...' -Level 'WARNING'
        & choco uninstall curl -y | Out-Null
        $retryExitCode = $LASTEXITCODE
        Write-LogMessage "choco uninstall curl (retry) returned exit code: $retryExitCode"

        if ($retryExitCode -ne 0) {
            Write-LogMessage 'curl uninstall retry failed.' -Level 'WARNING'
        }
        else {
            Write-LogMessage 'Chocolatey curl successfully uninstalled on retry.'
        }
    }
    else {
        Write-LogMessage 'Chocolatey curl successfully uninstalled.'
    }

    Write-LogMessage 'System32 curl maintenance completed.'
}

function Invoke-GitMaintenance {
    Write-LogMessage 'Starting git maintenance...'

    # gc.auto is set to 0 in VMBuild.cmd to prevent pack-file contention
    # during fetch/pull on Windows (inline gc tries to rewrite packs while
    # fetch still holds handles -> "Unlink of file ... failed" hang).
    # Run gc explicitly here where nothing else is using the repo.
    $repoRoot = Split-Path $scriptPath -Parent
    try {
        $gcOutput = & git -C $repoRoot gc 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-LogMessage 'git gc completed successfully.'
        }
        else {
            Write-LogMessage "git gc returned exit code $LASTEXITCODE : $gcOutput" -Level 'WARNING'
        }
    }
    catch {
        Write-LogMessage "git gc threw: $_" -Level 'WARNING'
    }

    # Exclude .git from Windows Defender real-time scanning.
    # Defender holds file handles during scan, contributing to pack-file
    # locking when git rewrites packs.
    $repoGitDir = Join-Path $repoRoot '.git'
    if (Test-Path $repoGitDir) {
        try {
            $prefs = Get-MpPreference -ErrorAction Stop
            if ($prefs.ExclusionPath -notcontains $repoGitDir) {
                Add-MpPreference -ExclusionPath $repoGitDir -ErrorAction Stop
                Write-LogMessage "Added Defender exclusion for $repoGitDir"
            }
        }
        catch {
            # Non-fatal: Defender may not be present or we may lack permissions
            Write-LogMessage "Could not configure Defender exclusion: $_" -Level 'WARNING'
        }
    }

    Write-LogMessage 'Git maintenance completed.'
}

function Invoke-DotNet6Maintenance {
    Write-LogMessage 'Starting .NET 6 maintenance...'

    $dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnetCommand) {
        Write-LogMessage '.NET CLI not found. Skipping .NET 6 detection/removal.'
        return
    }

    Write-LogMessage "dotnet CLI found at: $($dotnetCommand.Source)"

    $dotnet6Found = $false
    Write-LogMessage 'Checking for .NET 6 runtimes...'
    $runtimeMatches = & $dotnetCommand.Source --list-runtimes 2>$null | Select-String -Pattern ' 6\.[0-9]'
    if ($runtimeMatches) {
        Write-LogMessage "Found .NET 6 runtimes: $($runtimeMatches -join ', ')"
        $dotnet6Found = $true
    }

    Write-LogMessage 'Checking for .NET 6 SDKs...'
    $sdkMatches = & $dotnetCommand.Source --list-sdks 2>$null | Select-String -Pattern '^6\.[0-9]'
    if ($sdkMatches) {
        Write-LogMessage "Found .NET 6 SDKs: $($sdkMatches -join ', ')"
        $dotnet6Found = $true
    }

    if (-not $dotnet6Found) {
        Write-LogMessage '.NET 6 not detected. Skipping .NET 6 removal.'
        return
    }

    Write-LogMessage '.NET 6 detected. Attempting uninstall using registered Windows uninstall entries...'

    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    Write-LogMessage "Scanning registry uninstall paths: $($paths -join '; ')"

    $items = @()
    foreach ($path in $paths) {
        $items += @(Get-ItemProperty -Path $path -ErrorAction SilentlyContinue)
    }

    Write-LogMessage "Total registry entries scanned: $($items.Count)"

    $targets = @()
    foreach ($item in $items) {
        if ($item.DisplayName -and $item.DisplayVersion -and $item.DisplayVersion -like '6.*') {
            if (
                $item.DisplayName -like 'Microsoft .NET*' -or
                $item.DisplayName -like 'Microsoft ASP.NET Core*' -or
                $item.DisplayName -like 'Microsoft Windows Desktop Runtime*'
            ) {
                $targets += $item
                Write-LogMessage "Identified .NET 6 component for uninstall: '$($item.DisplayName)' (Version: $($item.DisplayVersion))"
            }
        }
    }

    if ($targets.Count -eq 0) {
        Write-LogMessage '.NET 6 components detected via dotnet CLI, but no matching uninstall entries found in registry.' -Level 'WARNING'
        return
    }

    Write-LogMessage "Found $($targets.Count) .NET 6 component(s) to uninstall."

    $hadFailure = $false
    $uninstallCount = 0
    $successCount = 0
    $alreadyAbsentCount = 0

    foreach ($target in $targets) {
        $uninstall = $target.QuietUninstallString
        if (-not $uninstall) {
            $uninstall = $target.UninstallString
        }

        if ([string]::IsNullOrWhiteSpace($uninstall)) {
            Write-LogMessage "No uninstall string found for '$($target.DisplayName)'. Skipping." -Level 'WARNING'
            continue
        }

        Write-LogMessage "Processing uninstall for: '$($target.DisplayName)' (Version: $($target.DisplayVersion))"
        Write-LogMessage "Original uninstall string: $uninstall"

        if ($uninstall -match 'msiexec') {
            Write-LogMessage 'Detected MSI-based uninstall.'

            if ($uninstall -match '(/i|/I)') {
                Write-LogMessage 'Converting /I to /X for MSI uninstall...'
                $uninstall = $uninstall -replace '(/i|/I)', '/x'
            }

            if ($uninstall -notmatch '(/qn|/quiet)') {
                Write-LogMessage 'Adding /qn flag for quiet uninstall.'
                $uninstall += ' /qn'
            }

            if ($uninstall -notmatch '/norestart') {
                Write-LogMessage 'Adding /norestart flag.'
                $uninstall += ' /norestart'
            }
        }
        else {
            Write-LogMessage 'Detected non-MSI uninstall.'

            if ($uninstall -notmatch '(/qn|/quiet)') {
                Write-LogMessage 'Adding /quiet flag.'
                $uninstall += ' /quiet'
            }

            if ($uninstall -notmatch '/norestart') {
                Write-LogMessage 'Adding /norestart flag.'
                $uninstall += ' /norestart'
            }
        }

        Write-LogMessage "Final uninstall command: $uninstall"

        $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $uninstall -Wait -PassThru -WindowStyle Hidden
        $uninstallCount++

        Write-LogMessage "Uninstall process exited with code: $($proc.ExitCode)"

        if ($proc.ExitCode -eq 0) {
            Write-LogMessage "Successfully uninstalled: '$($target.DisplayName)'"
            $successCount++
        }
        elseif ($proc.ExitCode -eq 1605 -or $proc.ExitCode -eq 1614) {
            Write-LogMessage "Component already removed or not present: '$($target.DisplayName)' (Exit code: $($proc.ExitCode))" -Level 'WARNING'
            $alreadyAbsentCount++
        }
        else {
            Write-LogMessage "Uninstall failed for '$($target.DisplayName)' (Exit code: $($proc.ExitCode))" -Level 'ERROR'
            $hadFailure = $true
        }
    }

    Write-LogMessage ".NET 6 uninstall summary: $successCount successful, $alreadyAbsentCount already absent, $($uninstallCount - $successCount - $alreadyAbsentCount) failed (total: $uninstallCount)"

    if ($hadFailure) {
        Write-LogMessage 'One or more .NET 6 uninstall operations failed.' -Level 'WARNING'
    }
    else {
        Write-LogMessage 'All .NET 6 components successfully uninstalled.'
    }

    Write-LogMessage '.NET 6 maintenance completed.'
}

function Invoke-WindowsTerminalMaintenance {
    Write-LogMessage 'Starting Windows Terminal maintenance...'

    $wtFound = $null -ne (Get-Command wt.exe -ErrorAction SilentlyContinue)

    if ($wtFound) {
        Write-LogMessage 'Windows Terminal already installed. Skipping installation.'
        return
    }

    Write-LogMessage 'Windows Terminal not installed, attempting to install...'

    if (-not (Test-ChocoAvailable)) {
        Write-LogMessage 'Chocolatey CLI not found. Skipping Windows Terminal install.' -Level 'WARNING'
        return
    }

    & choco install microsoft-ui-xaml -y | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-LogMessage 'Failed to install microsoft-ui-xaml.' -Level 'WARNING'
    }
    else {
        Write-LogMessage 'microsoft-ui-xaml successfully installed.'
    }

    & choco install microsoft-windows-terminal -y | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-LogMessage 'Failed to install Windows Terminal.' -Level 'WARNING'
    }
    else {
        Write-LogMessage 'Windows Terminal successfully installed.'
    }

    Write-LogMessage 'Windows Terminal maintenance completed.'
}

function Install-DotNet9DesktopRuntime {
    # mRemoteNG 1.78+ uses .NET 9 WinForms — ensure the Desktop Runtime is installed
    $desktopRuntimePath = "$env:ProgramFiles\dotnet\shared\Microsoft.WindowsDesktop.App"
    $hasDesktopRuntime = (Test-Path $desktopRuntimePath) -and @(Get-ChildItem $desktopRuntimePath -Directory -Filter "9.*" -ErrorAction SilentlyContinue).Count -gt 0
    if (-not $hasDesktopRuntime) {
        if (Test-ChocoAvailable) {
            Write-LogMessage 'Installing .NET 9 Desktop Runtime (required by mRemoteNG WinForms)...'
            & choco install dotnet-9.0-desktopruntime -y | Out-Null
            if (Test-ChocoSuccessCode -Code $LASTEXITCODE) {
                Write-LogMessage '.NET 9 Desktop Runtime installed successfully.'
            }
            else {
                Write-LogMessage 'Failed to install .NET 9 Desktop Runtime.' -Level 'WARNING'
            }
        }
        else {
            Write-LogMessage '.NET 9 Desktop Runtime not found and Chocolatey unavailable. mRemoteNG may fail to launch.' -Level 'WARNING'
        }
    }
}

function Update-MRemoteNGShortcut {
    param([string]$ExePath)
    # Ensure desktop shortcut points to the correct exe and our connection XML
    $xmlPath = Join-Path $env:ProgramData "memlabs\memlabs-mremoteng.xml"
    $shortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "memlabs-mRemoteNG.lnk"
    $expectedArgs = "/cons:`"$xmlPath`""
    try {
        $shell = New-Object -ComObject WScript.Shell
        $needsUpdate = $true
        if (Test-Path $shortcutPath) {
            $existing = $shell.CreateShortcut($shortcutPath)
            if ($existing.TargetPath -eq $ExePath -and $existing.Arguments -eq $expectedArgs) {
                $needsUpdate = $false
            }
        }
        if ($needsUpdate) {
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $ExePath
            $shortcut.Arguments = $expectedArgs
            $shortcut.WorkingDirectory = Split-Path $ExePath
            $shortcut.Save()
            Write-LogMessage "Updated desktop shortcut to $ExePath with /cons: $xmlPath"
        }
    }
    catch {
        Write-LogMessage "Could not update desktop shortcut: $_" -Level 'WARNING'
    }

    # Workaround: mRemoteNG 1.78.2 /cons: CLI argument is broken — GetStartupConnectionFileName()
    # reads OptionsConnectionsPage.Default.ConnectionFilePath but /cons: writes to the old
    # OptionsBackupPage.Default.BackupLocation (dead code path). Symlink the default confCons.xml
    # to our memlabs XML so mRemoteNG loads it without needing /cons:.
    # The nightly build is portable, so the default path is the install directory (next to the exe).
    if (Test-Path $xmlPath) {
        # Portable edition: confCons.xml lives next to mRemoteNG.exe
        $installDir = Split-Path $ExePath
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
                $isCorrectSymlink = $item -and $item.LinkTarget -eq $xmlPath
                if (-not $isCorrectSymlink) {
                    if (Test-Path $defaultFile) { Remove-Item $defaultFile -Force }
                    New-Item -ItemType SymbolicLink -Path $defaultFile -Target $xmlPath -Force | Out-Null
                    Write-LogMessage "Symlinked $defaultFile -> $xmlPath"
                }
            }
            catch {
                Write-LogMessage "Could not create symlink at $defaultFile`: $_" -Level 'WARNING'
            }
        }
    }
}

function Invoke-MRemoteNGMaintenance {
    Write-LogMessage 'Starting mRemoteNG maintenance...'

    # mRemoteNG 1.77+ nightly builds support Hyper-V Console via UseVmId/UseEnhancedMode.
    # The stable choco package (1.76.20) does not. We install the nightly portable build from GitHub.
    $minVersion = [version]"1.77.0"
    $installDir = Join-Path $env:ProgramData "memlabs\mRemoteNG"
    $mRNGExe = Join-Path $installDir "mRemoteNG.exe"

    # Check all known install locations for a sufficient version
    $candidatePaths = @(
        $mRNGExe
        "$env:ProgramFiles\mRemoteNG\mRemoteNG.exe"
        "${env:ProgramFiles(x86)}\mRemoteNG\mRemoteNG.exe"
        "C:\ProgramData\chocolatey\lib\mremoteng\tools\mRemoteNG.exe"
    )
    foreach ($candidate in $candidatePaths) {
        if (Test-Path $candidate) {
            try {
                $vi = (Get-Item $candidate).VersionInfo
                $ver = [version]"$($vi.FileMajorPart).$($vi.FileMinorPart).$($vi.FileBuildPart)"
                if ($ver -ge $minVersion) {
                    Write-LogMessage "mRemoteNG $ver found at $candidate. No upgrade needed."
                    # Still ensure .NET 9 Desktop Runtime is present (required by 1.78+ WinForms)
                    Install-DotNet9DesktopRuntime
                    Update-MRemoteNGShortcut -ExePath $candidate
                    return
                }
                Write-LogMessage "mRemoteNG $ver at $candidate is below $minVersion (no Hyper-V Console support)."
            }
            catch {
                Write-LogMessage "Could not read version from $candidate`: $_"
            }
        }
    }

    Write-LogMessage 'Installing mRemoteNG nightly (1.78+) for Hyper-V Console support...'

    # Use the GitHub API to find the latest nightly with a self-contained (SC) portable asset
    $downloadUrl = $null
    $assetName = $null
    try {
        $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/mRemoteNG/mRemoteNG/releases" `
            -UserAgent 'MemLabs-Maintenance' -TimeoutSec 30 -ErrorAction Stop

        $release = $releases | Where-Object {
            $_.assets | Where-Object { $_.name -match 'x64-SC\.rar$' }
        } | Select-Object -First 1

        if ($release) {
            $asset = $release.assets | Where-Object { $_.name -match 'x64-SC\.rar$' } | Select-Object -First 1
            $downloadUrl = $asset.browser_download_url
            $assetName = $asset.name
            Write-LogMessage "Found release: $($release.name) - $assetName"
        }
    }
    catch {
        Write-LogMessage "GitHub API call failed: $_. Using known-good URL." -Level 'WARNING'
    }

    # Fall back to the known-good nightly if API failed or returned nothing
    if (-not $downloadUrl) {
        $downloadUrl = "https://github.com/mRemoteNG/mRemoteNG/releases/download/20260222-v1.78.2-NB-(3405)/mRemoteNG-20260222-v1.78.2-NB-3405-x64-SC.rar"
        $assetName = "mRemoteNG-20260222-v1.78.2-NB-3405-x64-SC.rar"
        Write-LogMessage "Using known-good URL: $assetName"
    }

    # Ensure 7-Zip is available for RAR extraction
    $7zExe = $null
    foreach ($p in @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe", "C:\ProgramData\chocolatey\bin\7z.exe")) {
        if (Test-Path $p) { $7zExe = $p; break }
    }
    if (-not $7zExe) {
        if (Test-ChocoAvailable) {
            Write-LogMessage 'Installing 7-Zip for RAR extraction...'
            & choco install 7zip.portable -y | Out-Null
            if (Test-ChocoSuccessCode -Code $LASTEXITCODE) {
                $7zExe = "C:\ProgramData\chocolatey\bin\7z.exe"
            }
        }
        if (-not $7zExe -or -not (Test-Path $7zExe)) {
            Write-LogMessage '7-Zip not available and cannot be installed. Skipping mRemoteNG install.' -Level 'WARNING'
            return
        }
    }

    # Download the nightly build
    $tempDir = Join-Path $env:TEMP "mremoteng-install"
    $null = New-Item -Path $tempDir -ItemType Directory -Force
    $downloadPath = Join-Path $tempDir $assetName

    try {
        Write-LogMessage "Downloading $assetName..."
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $downloadUrl -OutFile $downloadPath -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
        Write-LogMessage "Download complete ($('{0:N1}' -f ((Get-Item $downloadPath).Length / 1MB)) MB)."
    }
    catch {
        Write-LogMessage "Download failed: $_" -Level 'WARNING'
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        return
    }

    # Stop mRemoteNG if running
    $mRNGProcs = Get-Process -Name mRemoteNG -ErrorAction SilentlyContinue
    if ($mRNGProcs) {
        Write-LogMessage 'Stopping running mRemoteNG process...'
        $mRNGProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    # Remove old choco 1.76 installation if present
    $oldChocoExe = "${env:ProgramFiles(x86)}\mRemoteNG\mRemoteNG.exe"
    if ((Test-Path $oldChocoExe) -and (Test-ChocoAvailable)) {
        Write-LogMessage 'Removing old mRemoteNG choco package (1.76)...'
        & choco uninstall mremoteng -y 2>&1 | Out-Null
    }

    # Remove old Program Files install if present (moved to ProgramData\memlabs)
    $oldPFDir = "$env:ProgramFiles\mRemoteNG"
    if (Test-Path $oldPFDir) {
        Write-LogMessage "Removing old install at $oldPFDir..."
        Remove-Item -Path $oldPFDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Extract to install directory
    if (Test-Path $installDir) {
        Remove-Item -Path $installDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $null = New-Item -Path $installDir -ItemType Directory -Force

    try {
        Write-LogMessage "Extracting to $installDir..."
        & $7zExe x $downloadPath -o"$installDir" -y 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "7z extraction failed with exit code $LASTEXITCODE" }

        # RAR may contain a subfolder; if so, move contents up
        if (-not (Test-Path $mRNGExe)) {
            $subDirs = Get-ChildItem -Path $installDir -Directory
            if ($subDirs.Count -eq 1) {
                $subDir = $subDirs[0].FullName
                Write-LogMessage "Moving contents from subfolder $($subDirs[0].Name)..."
                Get-ChildItem -Path $subDir -Force | Move-Item -Destination $installDir -Force
                Remove-Item $subDir -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        Write-LogMessage "Extraction failed: $_" -Level 'WARNING'
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        return
    }

    # Cleanup temp download
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

    if (Test-Path $mRNGExe) {
        $vi = (Get-Item $mRNGExe).VersionInfo
        Write-LogMessage "mRemoteNG $($vi.FileVersion) installed successfully at $installDir"
    }
    else {
        Write-LogMessage "mRemoteNG.exe not found after extraction at $installDir" -Level 'WARNING'
    }

    Install-DotNet9DesktopRuntime
    Update-MRemoteNGShortcut -ExePath $mRNGExe

    Write-LogMessage 'mRemoteNG maintenance completed.'
}

function Invoke-RdcManMaintenance {
    Write-LogMessage 'Starting RDCMan maintenance...'

    $minimumVersion = [version]'3.12.0.0'
    $installDirectory = 'C:\tools'
    $rdcManExe = Join-Path $installDirectory 'RDCMan.exe'
    $installedVersion = $null

    if (Test-Path $rdcManExe) {
        try {
            $installedVersion = [version](Get-Item $rdcManExe).VersionInfo.ProductVersion
        }
        catch {
            Write-LogMessage "Could not read the RDCMan version at '$rdcManExe': $_" -Level 'WARNING'
        }
    }

    $requiresInstall = -not $installedVersion -or $installedVersion -lt $minimumVersion
    $runningProcesses = @(Get-Process -Name RDCMan -ErrorAction SilentlyContinue)
    $hasIncompatibleRunningProcess = $false
    foreach ($runningProcess in $runningProcesses) {
        try {
            $runningVersion = [version](Get-Item $runningProcess.Path).VersionInfo.ProductVersion
            if ($runningVersion -lt $minimumVersion) {
                Write-LogMessage "Running RDCMan $runningVersion at '$($runningProcess.Path)' is below $minimumVersion."
                $hasIncompatibleRunningProcess = $true
            }
        }
        catch {
            Write-LogMessage "Could not verify running RDCMan process $($runningProcess.Id): $_" -Level 'WARNING'
            $hasIncompatibleRunningProcess = $true
        }
    }

    $restartAfterMaintenance = $false
    if ($runningProcesses.Count -gt 0 -and ($requiresInstall -or $hasIncompatibleRunningProcess)) {
        Write-LogMessage 'Stopping RDCMan to install or launch the compatible version...'
        $runningProcesses | Stop-Process -Force -ErrorAction Stop
        Start-Sleep -Seconds 1
        $restartAfterMaintenance = $true
    }

    if (-not $requiresInstall) {
        Write-LogMessage "RDCMan $installedVersion found at $rdcManExe. No upgrade needed."
    }
    else {
        if ($installedVersion) {
            Write-LogMessage "RDCMan $installedVersion is below the required version $minimumVersion."
        }
        else {
            Write-LogMessage "RDCMan $minimumVersion or newer was not found at $rdcManExe."
        }

        if (-not (Test-Path $installDirectory)) {
            New-Item -Path $installDirectory -ItemType Directory -Force | Out-Null
        }

        $downloadPath = Join-Path $env:TEMP "RDCMan-$([guid]::NewGuid().ToString('N')).exe"
        try {
            Write-LogMessage 'Downloading the latest RDCMan from Sysinternals...'
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri 'https://live.sysinternals.com/RDCMan.exe' -OutFile $downloadPath -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop

            $downloadedVersion = [version](Get-Item $downloadPath).VersionInfo.ProductVersion
            if ($downloadedVersion -lt $minimumVersion) {
                throw "Sysinternals supplied RDCMan $downloadedVersion; version $minimumVersion or newer is required."
            }

            Copy-Item -Path $downloadPath -Destination $rdcManExe -Force -ErrorAction Stop
            $installedVersion = [version](Get-Item $rdcManExe).VersionInfo.ProductVersion
            if ($installedVersion -lt $minimumVersion) {
                throw "RDCMan version verification failed after installation (found $installedVersion)."
            }

            Write-LogMessage "RDCMan $installedVersion installed successfully at $rdcManExe."
        }
        finally {
            $ProgressPreference = 'Continue'
            Remove-Item -Path $downloadPath -Force -ErrorAction SilentlyContinue
        }
    }

    if ($restartAfterMaintenance) {
        Start-Process -FilePath $rdcManExe -ArgumentList '/reconnect' -WorkingDirectory $installDirectory
        Write-LogMessage 'Restarted the compatible RDCMan executable.'
    }

    Write-LogMessage 'RDCMan maintenance completed.'
}

function Invoke-WeeklyUpgrades {
    Write-LogMessage 'Starting weekly upgrades...'

    if (-not (Test-ChocoAvailable)) {
        Write-LogMessage 'Chocolatey CLI not found. Skipping weekly upgrades.' -Level 'WARNING'
        return
    }

    $ps7Flag = Join-Path $env:ProgramData 'memlabs\ps7_upgrade.timestamp'
    $chocoAllFlag = Join-Path $env:ProgramData 'memlabs\choco_all_upgrade.timestamp'
    $now = Get-Date
    $weeklyInterval = [TimeSpan]::FromDays(7)

    # Ensure the directory exists
    $flagDir = Join-Path $env:ProgramData 'memlabs'
    if (-not (Test-Path $flagDir)) { New-Item -Path $flagDir -ItemType Directory -Force | Out-Null }

    $doPs7Upgrade = $true
    if (Test-Path $ps7Flag) {
        $lastRun = Get-Date (Get-Content $ps7Flag -ErrorAction SilentlyContinue)
        $elapsed = $now - $lastRun
        Write-LogMessage "Last PowerShell 7 upgrade: $($lastRun.ToString('yyyy-MM-dd HH:mm')) ($([int]$elapsed.TotalDays) days ago)"
        if ($elapsed -lt $weeklyInterval) {
            $doPs7Upgrade = $false
        }
    }

    $doChocoUpgrade = $true
    if (Test-Path $chocoAllFlag) {
        $lastChocoRun = Get-Date (Get-Content $chocoAllFlag -ErrorAction SilentlyContinue)
        $chocoElapsed = $now - $lastChocoRun
        Write-LogMessage "Last Chocolatey upgrade all: $($lastChocoRun.ToString('yyyy-MM-dd HH:mm')) ($([int]$chocoElapsed.TotalDays) days ago)"
        if ($chocoElapsed -lt $weeklyInterval) {
            $doChocoUpgrade = $false
        }
    }

    if ($doPs7Upgrade) {
        Write-LogMessage 'Upgrading PowerShell 7...'
        & choco upgrade pwsh -y
        $chocoRc = $LASTEXITCODE
        Write-LogMessage "choco upgrade pwsh returned exit code: $chocoRc"

        if (Test-ChocoSuccessCode -Code $chocoRc) {
            $now.ToString('o') | Out-File $ps7Flag -Encoding ascii -NoNewline
            Write-LogMessage 'PowerShell 7 upgrade completed successfully.'
        }
        else {
            Write-LogMessage "PowerShell 7 upgrade failed (exit code: $chocoRc)." -Level 'WARNING'
        }
    }
    else {
        Write-LogMessage 'PowerShell 7 upgrade skipped (less than 7 days since last run).'
    }

    if ($doChocoUpgrade) {
        # Launch choco upgrade all in a new window so it doesn't block the main script
        Write-LogMessage 'Launching Chocolatey upgrade all in new window...'
        $timestamp = $now.ToString('o')
        $scriptLines = @()
        $scriptLines += '$Host.UI.RawUI.WindowTitle = "MemLabs - Chocolatey Upgrades"'
        $scriptLines += "Write-Host 'Upgrading all Chocolatey packages...' -ForegroundColor Cyan"
        $scriptLines += '& choco upgrade all -y --ignore-checksums'
        $scriptLines += 'if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3010) {'
        $scriptLines += "    '$timestamp' | Out-File '$chocoAllFlag' -Encoding ascii -NoNewline"
        $scriptLines += "    Write-Host 'Chocolatey package upgrade completed successfully.' -ForegroundColor Green"
        $scriptLines += '} else {'
        $scriptLines += '    Write-Host "Chocolatey package upgrade failed (exit code: $LASTEXITCODE)." -ForegroundColor Yellow'
        $scriptLines += '}'
        $scriptLines += "Write-Host ''"
        $scriptLines += "Write-Host 'Done. This window will close in 10 seconds...' -ForegroundColor Cyan"
        $scriptLines += 'Start-Sleep -Seconds 10'

        $scriptContent = $scriptLines -join "`n"
        $chocoScriptPath = Join-Path $env:TEMP 'memlabs_choco_upgrade.ps1'
        $scriptContent | Out-File $chocoScriptPath -Encoding utf8

        Start-Process pwsh -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $chocoScriptPath -WindowStyle Normal
        Write-LogMessage 'Chocolatey upgrade all launched in a new window (non-blocking).'
    }
    else {
        Write-LogMessage 'Chocolatey upgrade all skipped (less than 7 days since last run).'
    }

    Write-LogMessage 'Weekly upgrades maintenance completed.'
}

Write-LogMessage '========================================' 
Write-LogMessage 'Maintenance script started'
Write-LogMessage "Script path: $scriptPath"
Write-LogMessage "Log file: $logFile"
Write-LogMessage '========================================' 

try { Invoke-GitMaintenance } catch { Write-LogMessage "Git maintenance threw: $_" -Level 'ERROR'; $script:MaintenanceHadFailure = $true }
try { Invoke-System32CurlMaintenance } catch { Write-LogMessage "System32 curl maintenance threw: $_" -Level 'ERROR'; $script:MaintenanceHadFailure = $true }
try { Invoke-DotNet6Maintenance } catch { Write-LogMessage ".NET 6 maintenance threw: $_" -Level 'ERROR'; $script:MaintenanceHadFailure = $true }
try { Invoke-WindowsTerminalMaintenance } catch { Write-LogMessage "Windows Terminal maintenance threw: $_" -Level 'ERROR'; $script:MaintenanceHadFailure = $true }
try { Invoke-RdcManMaintenance } catch { Write-LogMessage "RDCMan maintenance threw: $_" -Level 'ERROR'; $script:MaintenanceHadFailure = $true }
try { Invoke-MRemoteNGMaintenance } catch { Write-LogMessage "mRemoteNG maintenance threw: $_" -Level 'ERROR'; $script:MaintenanceHadFailure = $true }
try { Invoke-WeeklyUpgrades } catch { Write-LogMessage "Weekly upgrades threw: $_" -Level 'ERROR'; $script:MaintenanceHadFailure = $true }

Write-LogMessage '========================================' 
Write-LogMessage 'Maintenance script completed'
Write-LogMessage "Log file: $logFile"
Write-LogMessage '========================================' 

if ($script:MaintenanceHadFailure) {
    exit 1
}
exit 0
