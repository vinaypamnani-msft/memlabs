[CmdletBinding()]
param (
    # Re-entry point: the removal relaunches this script with this switch so the uninstaller runs in
    # its own process and can never delay the VMBuild launch that is waiting on maintenance.
    [switch] $WindowsAdminCenterRemovalOnly
)

$ErrorActionPreference = 'Continue'

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$logsPath = Join-Path $scriptPath 'logs'
$logPrefix = if ($WindowsAdminCenterRemovalOnly) { 'WacRemoval' } else { 'Maintenance' }
$logFile = Join-Path $logsPath "${logPrefix}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

if (-not (Test-Path $logsPath)) {
    New-Item -ItemType Directory -Path $logsPath -Force | Out-Null
}

# Clean up old maintenance logs (keep only the 3 most recent)
$maintenanceLogs = Get-ChildItem -Path $logsPath -Filter "${logPrefix}_*.log" -ErrorAction SilentlyContinue | Sort-Object -Property CreationTime -Descending
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

function Get-InstalledPwshVersion {
    # Chocolatey's own package record goes stale when pwsh is upgraded outside of it,
    # so read the version off pwsh.exe. A chocolatey shim reports the shim's version.
    $candidates = @(Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
    $resolved = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($resolved -and $resolved.Source -notlike '*\chocolatey\*') {
        $candidates += $resolved.Source
    }

    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }

        $versionInfo = (Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue).VersionInfo
        if (-not $versionInfo -or $versionInfo.FileMajorPart -le 0) { continue }

        return [version]"$($versionInfo.FileMajorPart).$($versionInfo.FileMinorPart).$($versionInfo.FileBuildPart)"
    }

    return $null
}

function Get-ChocoAvailablePackageVersion {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId
    )

    $output = @(& choco search $PackageId --exact --limit-output)
    $searchRc = $LASTEXITCODE

    if (-not (Test-ChocoSuccessCode -Code $searchRc)) {
        Write-LogMessage "choco search $PackageId returned exit code $searchRc; cannot determine the available version." -Level 'WARNING'
        return $null
    }

    $idPattern = '^{0}\|(\d+(?:\.\d+){{1,3}})' -f [regex]::Escape($PackageId)
    foreach ($line in $output) {
        if ($line -match $idPattern) {
            return [version]$Matches[1]
        }
    }

    Write-LogMessage "choco search $PackageId reported no usable version; cannot compare it against the installed build." -Level 'WARNING'
    return $null
}

function Get-SevenZipPath {
    # First hit wins, so a Program Files install hides a chocolatey one - which is exactly
    # the state Invoke-SevenZipMaintenance exists to keep current.
    foreach ($candidate in @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe", "$env:ProgramData\chocolatey\bin\7z.exe")) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    return ''
}

function Get-SevenZipVersion {
    # Off the binary, never off a package record - 7-Zip here is routinely installed
    # outside any package manager, so no record is authoritative.
    param (
        [string]$Path
    )

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }

    $versionInfo = (Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue).VersionInfo
    if (-not $versionInfo -or $versionInfo.FileMajorPart -le 0) { return $null }

    # The file's own string, so the log matches what Add/Remove Programs shows: '26.02', not [version] 26.2.
    return $versionInfo.FileVersion
}

function Get-SevenZipChocoPackage {
    # The lib folder IS the ownership record, and reading it needs no choco process - which also
    # sidesteps 'choco list' differing between v1 (--local-only) and v2.
    $libRoot = Join-Path $env:ProgramData 'chocolatey\lib'
    foreach ($dir in @(Get-ChildItem -LiteralPath $libRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Name -match '(?i)^7zip') { return $dir.Name }
    }

    return ''
}

function Get-StaleSevenZipMsiEntry {
    # Chocolatey's 7zip.install runs the vendor EXE, which upgrades C:\Program Files\7-Zip in place
    # but leaves any earlier MSI's Add/Remove registration behind. Vulnerability scanners read that
    # registration, so the host keeps reporting the OLD version with no old files on disk.
    foreach ($entry in @(@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') |
            ForEach-Object { Get-ItemProperty -Path $_ -ErrorAction SilentlyContinue })) {
        if ("$($entry.DisplayName)" -notmatch '(?i)7-?zip') { continue }
        if ("$($entry.UninstallString)" -notmatch '(?i)msiexec') { continue }
        return $entry
    }

    return $null
}

$script:MaintenanceHadFailure = $false

function Set-MemLabsFileAssociation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [Microsoft.Win32.RegistryKey]$ClassesRoot,
        [Parameter(Mandatory = $true)]
        [string]$LauncherPath
    )

    $progId = 'MemLabs.Run'
    $openCommand = '"{0}" "%1"' -f $LauncherPath
    $registryValues = @(
        @{ SubKey = '.memlabs'; Value = $progId },
        @{ SubKey = $progId; Value = 'MemLabs configuration' },
        @{ SubKey = "$progId\shell\open\command"; Value = $openCommand }
    )
    $changed = $false

    foreach ($registryValue in $registryValues) {
        $key = $ClassesRoot.CreateSubKey($registryValue.SubKey)
        if ($null -eq $key) {
            throw "Could not open the per-user registry key '$($registryValue.SubKey)' for writing."
        }

        try {
            if ([string]$key.GetValue('') -ne $registryValue.Value) {
                $key.SetValue('', $registryValue.Value, [Microsoft.Win32.RegistryValueKind]::String)
                $changed = $true
            }
            if ([string]$key.GetValue('') -ne $registryValue.Value) {
                throw "Registry read-back failed for '$($registryValue.SubKey)'."
            }
        }
        finally {
            $key.Dispose()
        }
    }

    return $changed
}

function Invoke-MemLabsFileAssociationMaintenance {
    Write-LogMessage 'Starting MemLabs file association maintenance...'

    $progId = 'MemLabs.Run'
    $launcherPath = Join-Path $scriptPath 'VMBuild.cmd'
    $expectedCommand = '"{0}" "%1"' -f $launcherPath
    $acceptedCommands = @($expectedCommand, ('"{0}" %1' -f $launcherPath))

    if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
        throw "MemLabs launcher not found at '$launcherPath'."
    }

    $effectiveProgId = $null
    $effectiveCommand = $null
    $extensionKey = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey('.memlabs')
    try {
        if ($null -ne $extensionKey) {
            $effectiveProgId = [string]$extensionKey.GetValue('')
        }
    }
    finally {
        if ($null -ne $extensionKey) { $extensionKey.Dispose() }
    }

    $commandKey = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey("$progId\shell\open\command")
    try {
        if ($null -ne $commandKey) {
            $effectiveCommand = [string]$commandKey.GetValue('')
        }
    }
    finally {
        if ($null -ne $commandKey) { $commandKey.Dispose() }
    }

    if ($effectiveProgId -eq $progId -and $acceptedCommands -contains $effectiveCommand) {
        Write-LogMessage "The .memlabs association already opens '$launcherPath'."
        return
    }

    $classesRoot = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Classes')
    if ($null -eq $classesRoot) {
        throw 'Could not open the current user Classes registry key for writing.'
    }

    try {
        $changed = Set-MemLabsFileAssociation -ClassesRoot $classesRoot -LauncherPath $launcherPath
    }
    finally {
        $classesRoot.Dispose()
    }

    if ($changed) {
        if ($null -eq ('MemLabs.ShellNotification' -as [type])) {
            $nativeMethods = @'
[System.Runtime.InteropServices.DllImport("shell32.dll")]
public static extern void SHChangeNotify(uint eventId, uint flags, System.IntPtr item1, System.IntPtr item2);
'@
            Add-Type -Namespace MemLabs -Name ShellNotification -MemberDefinition $nativeMethods -ErrorAction Stop
        }
        [MemLabs.ShellNotification]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
        Write-LogMessage "Registered .memlabs files to open with '$launcherPath' for the current user."
    }
    else {
        Write-LogMessage 'The per-user .memlabs association is already current.'
    }
}

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

    # Keep Defender away from the host's high-I/O memlabs paths. In addition to
    # pack-file locking under .git, scanning VM disks, base images and ISO build
    # trees adds latency to every guest I/O or large host-side copy.
    $defenderPaths = New-Object System.Collections.Generic.List[string]
    function Add-DefenderPathCandidate {
        param([string]$Path)

        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        try {
            $fullPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
            $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
            if ([string]::IsNullOrWhiteSpace($pathRoot) -or -not [System.IO.Directory]::Exists($pathRoot)) { return }
            if ($fullPath.Length -gt $pathRoot.Length) { $fullPath = $fullPath.TrimEnd('\') }
            $defenderPaths.Add($fullPath)
        }
        catch {
            Write-LogMessage "Could not resolve Defender exclusion candidate '$Path': $_" -Level 'WARNING'
        }
    }

    foreach ($path in @(
            (Join-Path $repoRoot '.git')
            (Join-Path $scriptPath 'azureFiles')
            (Join-Path $scriptPath 'baseimagestaging\vhdx-base')
            (Join-Path $scriptPath 'baseimagestaging\vm')
            (Join-Path $scriptPath 'baseimagestaging\wim')
        )) {
        Add-DefenderPathCandidate -Path $path
    }

    # Match Get-MemlabsVmStorageRoot's non-interactive resolution order without
    # loading Common.ps1 (this maintenance script is intentionally standalone).
    $vmStorageRoot = $env:MEMLABS_VM_STORAGE_ROOT
    if ([string]::IsNullOrWhiteSpace($vmStorageRoot)) {
        $dataRoot = $env:MEMLABS_DATA_ROOT
        if ([string]::IsNullOrWhiteSpace($dataRoot)) {
            $programData = if ([string]::IsNullOrWhiteSpace($env:ProgramData)) { 'C:\ProgramData' } else { $env:ProgramData }
            $dataRoot = Join-Path $programData 'memlabs'
        }
        $hostSettingsPath = Join-Path $dataRoot 'host-settings.json'
        if (Test-Path -LiteralPath $hostSettingsPath) {
            try {
                $hostSettings = Get-Content -LiteralPath $hostSettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ($hostSettings.PSObject.Properties['vmStorageRoot']) {
                    $savedVmStorageRoot = [string]$hostSettings.vmStorageRoot
                    $savedPathRoot = [System.IO.Path]::GetPathRoot($savedVmStorageRoot)
                    if ($savedPathRoot -and [System.IO.Directory]::Exists($savedPathRoot)) {
                        $vmStorageRoot = $savedVmStorageRoot
                    }
                }
            }
            catch {
                Write-LogMessage "Could not read VM storage root from $hostSettingsPath`: $_" -Level 'WARNING'
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($vmStorageRoot) -and [System.IO.Directory]::Exists('E:\')) {
        $vmStorageRoot = 'E:\VirtualMachines'
    }
    Add-DefenderPathCandidate -Path $vmStorageRoot

    try {
        $prefs = Get-MpPreference -ErrorAction Stop
        $existingPaths = @($prefs.ExclusionPath | Where-Object { $_ })
        $newPaths = @($defenderPaths | Sort-Object -Unique | Where-Object { $existingPaths -notcontains $_ })
        if ($newPaths.Count -gt 0) {
            Add-MpPreference -ExclusionPath $newPaths -ErrorAction Stop
            Write-LogMessage "Added Defender exclusions: $($newPaths -join '; ')"
        }
        else {
            Write-LogMessage 'Defender exclusions already current.'
        }
    }
    catch {
        # Non-fatal: Defender may not be present or we may lack permissions
        Write-LogMessage "Could not configure Defender exclusions: $_" -Level 'WARNING'
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

function Get-InstalledEntry {
    param (
        [Parameter(Mandatory = $true)][string] $NameLike
    )

    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $found = @()
    foreach ($path in $paths) {
        foreach ($item in @(Get-ItemProperty -Path $path -ErrorAction SilentlyContinue)) {
            if ($item.DisplayName -like $NameLike) { $found += $item }
        }
    }

    return $found
}

function ConvertTo-QuietUninstallCommand {
    param (
        [Parameter(Mandatory = $true)] $Entry
    )

    $command = $Entry.QuietUninstallString
    if (-not $command) { $command = $Entry.UninstallString }
    if ([string]::IsNullOrWhiteSpace($command)) { return '' }

    if ($command -match 'msiexec') {
        $command = $command -replace '(?i)/i', '/x'
        if ($command -notmatch '(?i)(/qn|/quiet)') { $command += ' /qn' }
    }
    elseif ($command -match '(?i)unins\d*\.exe') {
        # Inno Setup. /SUPPRESSMSGBOXES only takes effect alongside /VERYSILENT, and without
        # /NORESTART a /VERYSILENT uninstall reboots the host without asking.
        $exe = if ($command -match '^\s*"([^"]+)"') { $Matches[1] } else { ($command -split '\s+')[0] }
        return '"{0}" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -f $exe
    }
    elseif ($command -notmatch '(?i)(/qn|/quiet|/S\b)') {
        $command += ' /quiet'
    }

    if ($command -notmatch '(?i)/norestart') { $command += ' /norestart' }
    return $command
}

function Stop-ProcessTree {
    param (
        [Parameter(Mandatory = $true)]
        [int] $ProcessId
    )

    # Depth first: the uninstaller shells out one powershell.exe per cleanup step and waits on it, so
    # the blocked child is the thing actually holding the tree up. Killing only the parent orphans
    # the unins*.tmp clone that owns the unins*.dat lock, which then fails the next run with Error 32.
    foreach ($child in @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue)) {
        Stop-ProcessTree -ProcessId ([int] $child.ProcessId)
    }

    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Invoke-WindowsAdminCenterRemoval {
    Write-LogMessage 'Checking for Windows Admin Center...'

    # The host ARM template (azuredeploysmall) installed WAC via an AdminCenter extension until
    # 602b3494 dropped it on 2026-08-21, and nothing ever updated it. Hosts deployed before then
    # still carry 2.0.0.112 against a current 2.7.4.18, which is what the vulnerability scan flags.
    if (@(Get-InstalledEntry -NameLike 'Windows Admin Center*').Count -eq 0) {
        Write-LogMessage 'Windows Admin Center is not installed. Nothing to remove.'
        return
    }

    # One removal at a time: a wedged uninstaller can outlive the launch that started it, and a
    # second one would fight the first for the unins*.dat lock.
    $lockFile = Join-Path $env:TEMP 'memlabs_wac_removal.pid'
    if (Test-Path -LiteralPath $lockFile) {
        $existingPid = 0
        $lockText = @(Get-Content -LiteralPath $lockFile -ErrorAction SilentlyContinue)[0]
        if ([int]::TryParse($lockText, [ref] $existingPid)) {
            $running = Get-Process -Id $existingPid -ErrorAction SilentlyContinue
            if ($running -and $running.ProcessName -eq 'powershell') {
                Write-LogMessage "A Windows Admin Center removal is already running (PID $existingPid). Skipping this launch."
                return
            }
        }
    }

    # Its own process, deliberately not waited on: VMBuild.cmd runs this script synchronously, so an
    # uninstall that stalls for its full timeout would otherwise be added to every build launch.
    $worker = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoLogo', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"", '-WindowsAdminCenterRemovalOnly'
    )
    Set-Content -LiteralPath $lockFile -Value $worker.Id -Encoding ascii
    Write-LogMessage "Windows Admin Center removal launched in its own process (PID $($worker.Id), non-blocking). It writes WacRemoval_*.log under $logsPath."
}

function Invoke-WindowsAdminCenterRemovalWorker {
    param (
        [int] $UninstallTimeoutSeconds = 600,
        [int] $VerifyTimeoutSeconds = 180
    )

    Write-LogMessage 'Starting Windows Admin Center removal...'

    $entries = @(Get-InstalledEntry -NameLike 'Windows Admin Center*')
    if ($entries.Count -eq 0) {
        Write-LogMessage 'Windows Admin Center is not installed. Nothing to remove.'
        return
    }

    # Do NOT stop or disable the WindowsAdminCenter services first: the uninstaller runs its own
    # Stop-WACService / Stop-WACLauncher as its first two steps.
    foreach ($entry in $entries) {
        Write-LogMessage "Found '$($entry.DisplayName)' version $($entry.DisplayVersion)."

        $command = ConvertTo-QuietUninstallCommand -Entry $entry
        if (-not $command) {
            Write-LogMessage "No uninstall string for '$($entry.DisplayName)', so it cannot be removed automatically." -Level 'WARNING'
            continue
        }

        # Inno logs each step it shells out to, which is the only thing that names a stalled step.
        $innoLog = $null
        if ($command -match '(?i)unins\d*\.exe') {
            $innoLog = Join-Path $env:TEMP ('wac-uninstall-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
            $command += " /LOG=`"$innoLog`""
        }

        Write-LogMessage "Uninstalling with: $command"
        $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $command -PassThru -WindowStyle Hidden
        if ($proc.WaitForExit($UninstallTimeoutSeconds * 1000)) {
            Write-LogMessage "Uninstall exited with code: $($proc.ExitCode)"
            continue
        }

        $step = $null
        if ($innoLog -and (Test-Path -LiteralPath $innoLog)) {
            $step = @(Get-Content -LiteralPath $innoLog -ErrorAction SilentlyContinue |
                    Where-Object { $_ -match 'Running Exec parameters:' } | Select-Object -Last 1)[0]
        }
        $where = if ($step) { " It was last running: $($step.Trim())" } elseif ($innoLog) { " No step was logged to ${innoLog}." } else { '' }

        # Killed rather than left running: a stalled tree keeps the unins*.dat lock, so leaving it
        # would make every later launch start another one that cannot succeed either.
        Write-LogMessage "Uninstaller for '$($entry.DisplayName)' has not exited after $UninstallTimeoutSeconds seconds.$where Killing the process tree." -Level 'WARNING'
        Stop-ProcessTree -ProcessId $proc.Id
    }

    # The exit code is the uninstaller's opinion; the registry is the fact. Inno's unins*.exe also
    # relaunches itself from TEMP and the process we waited on can exit first, so poll rather than
    # read once.
    $remaining = @(Get-InstalledEntry -NameLike 'Windows Admin Center*')
    $deadline = (Get-Date).AddSeconds($VerifyTimeoutSeconds)
    while ($remaining.Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $remaining = @(Get-InstalledEntry -NameLike 'Windows Admin Center*')
    }

    if ($remaining.Count -eq 0) {
        Write-LogMessage 'Windows Admin Center removed.'
    }
    else {
        Write-LogMessage "Windows Admin Center is still registered after $VerifyTimeoutSeconds seconds: $(($remaining | ForEach-Object { "$($_.DisplayName) $($_.DisplayVersion)" }) -join ', ')" -Level 'WARNING'
    }

    Write-LogMessage 'Windows Admin Center removal completed.'
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

function Invoke-SevenZipMaintenance {
    Write-LogMessage 'Starting 7-Zip maintenance...'

    $installedPath = Get-SevenZipPath
    $installed = Get-SevenZipVersion -Path $installedPath
    $owner = Get-SevenZipChocoPackage

    if ($installed) { Write-LogMessage "7-Zip $installed is installed at $installedPath." }
    else { Write-LogMessage '7-Zip is not installed on this host.' }

    if ($owner) {
        Write-LogMessage "Chocolatey package '$owner' owns it, so the weekly 'choco upgrade all' keeps it current."
    }
    elseif (-not (Test-ChocoAvailable)) {
        Write-LogMessage 'No Chocolatey package owns 7-Zip and the CLI is missing, so nothing on this host can update it. Its currency is UNKNOWN, not current.' -Level 'WARNING'
    }
    else {
        # MEASURED on a lab host 2026-09-01: 7-Zip 24.08 with InstallSource '<repo>\vmbuild\azureFiles\tools\'
        # and no package owning it, so 'choco upgrade all' could never reach it. Adopting it is what
        # puts it under the existing weekly upgrade; measured to take 24.08 to 26.02 in place.
        # 7zip.install, never 7zip.portable: portable only shims chocolatey\bin, which Get-SevenZipPath
        # reaches last, so a stale Program Files copy would keep winning and the upgrades go unused.
        Write-LogMessage 'No Chocolatey package owns 7-Zip. Adopting it so the weekly upgrade covers it...'
        & choco install 7zip.install -y | Out-Null
        $chocoRc = $LASTEXITCODE
        Write-LogMessage "choco install 7zip.install returned exit code: $chocoRc"

        if (Test-ChocoSuccessCode -Code $chocoRc) {
            # A success exit code is choco's opinion; the file version and the lib folder are the facts.
            $installedPath = Get-SevenZipPath
            $installed = Get-SevenZipVersion -Path $installedPath
            $owner = Get-SevenZipChocoPackage
            if ($owner) { Write-LogMessage "7-Zip $installed at $installedPath is now owned by '$owner'." }
            else { Write-LogMessage 'choco reported success but no 7zip* folder exists under chocolatey\lib, so nothing owns 7-Zip yet.' -Level 'WARNING' }
        }
        else {
            Write-LogMessage "Could not adopt 7-Zip into Chocolatey (exit code $chocoRc). It stays unmanaged at $installed." -Level 'WARNING'
        }
    }

    $stale = Get-StaleSevenZipMsiEntry
    if ($owner -and $null -ne $stale) {
        # MEASURED 2026-09-01: /X on that product code took C:\Program Files\7-Zip from 107 files to 1.
        # Windows Installer removes the files it owns even though a later EXE installer overwrote them.
        $installDir = if ($installedPath) { Split-Path $installedPath -Parent } else { 'the 7-Zip install folder' }
        Write-LogMessage ("An orphaned 7-Zip MSI registration remains: '$($stale.DisplayName)' version $($stale.DisplayVersion). " +
            "No files of that version are on disk, but vulnerability scanners read Add/Remove Programs and will keep " +
            "reporting it. Clearing it takes TWO commands run by hand, in this order, because the uninstall WILL " +
            "delete the current files out of ${installDir}: " +
            "$($stale.UninstallString -replace '(?i)/I', '/X') /qn /norestart " +
            "followed by 'choco install 7zip.install -y --force' to put 7-Zip back.") -Level 'WARNING'
    }

    Write-LogMessage '7-Zip maintenance completed.'
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

function Set-MRemoteNGDpiCompatibility {
    param([string]$ExePath)

    # The 1.78 nightly advertises per-monitor DPI awareness but lays out and hit-tests at a different
    # scale than it renders, so on a scaled display clicks land inches right of the control drawn.
    # Forcing System awareness makes Windows own the scaling, which keeps the geometry consistent.
    if (-not $ExePath -or -not (Test-Path $ExePath)) { return }

    $layersKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
    $dpiTokens = @('HIGHDPIAWARE', 'DPIUNAWARE', 'GDIDPISCALING', 'PERPROCESSSYSTEMDPIFORCEOFF', 'PERPROCESSSYSTEMDPIFORCEON')

    try {
        if (-not (Test-Path $layersKey)) { $null = New-Item -Path $layersKey -Force }

        $existing = ''
        $props = Get-ItemProperty -LiteralPath $layersKey -ErrorAction SilentlyContinue
        if ($null -ne $props -and $props.PSObject.Properties.Name -contains $ExePath) {
            $existing = [string]$props.$ExePath
        }

        # Any DPI token already here was chosen by a human - never overwrite their choice.
        $tokens = @($existing -split '\s+' | Where-Object { $_ })
        $already = @($tokens | Where-Object { $dpiTokens -contains $_.ToUpperInvariant() })
        if ($already.Count -gt 0) {
            Write-LogMessage "mRemoteNG DPI compatibility is already set ('$existing'). Leaving it as-is."
            return
        }

        # '~' is the layer-list marker; the other tokens (RUNASADMIN etc.) must survive.
        $merged = @('~') + @($tokens | Where-Object { $_ -ne '~' }) + @('HIGHDPIAWARE')
        Set-ItemProperty -LiteralPath $layersKey -Name $ExePath -Value ($merged -join ' ') -Type String
        Write-LogMessage "Set mRemoteNG DPI scaling to System for $ExePath (fixes mouse clicks landing off-target on scaled displays)."
    }
    catch {
        Write-LogMessage "Could not set mRemoteNG DPI compatibility: $_" -Level 'WARNING'
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
                    Set-MRemoteNGDpiCompatibility -ExePath $candidate
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
    $7zExe = Get-SevenZipPath
    if (-not $7zExe) {
        if (Test-ChocoAvailable) {
            Write-LogMessage 'Installing 7-Zip for RAR extraction...'
            & choco install 7zip.install -y | Out-Null
            if (Test-ChocoSuccessCode -Code $LASTEXITCODE) {
                $7zExe = Get-SevenZipPath
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
    Set-MRemoteNGDpiCompatibility -ExePath $mRNGExe

    Write-LogMessage 'mRemoteNG maintenance completed.'
}

function Invoke-RdcManMaintenance {
    Write-LogMessage 'Starting RDCMan maintenance...'

    # RDCMan 3.21 prompts to trust a certificate for every lab VM, so MemLabs prefers
    # 3.12.0.0 -- but keeps its OWN copy under ProgramData instead of holding back
    # C:\tools, which belongs to the chocolatey sysinternals package. Sysinternals stays
    # free to update; MemLabs just stops using its RDCMan when it has a better option.
    #
    # live.sysinternals.com is deliberately NOT used: it only serves the current build.
    # If 3.12 cannot be obtained, the sysinternals copy is used as-is and the .rdg
    # cert-trust entries switch themselves on to suppress the prompt.
    $pinnedVersion = [version]'3.12.0.0'
    $pinnedDir = Join-Path $env:ProgramData 'memlabs\RDCMan'
    $pinnedExe = Join-Path $pinnedDir 'RDCMan.exe'
    $sysinternalsExe = 'C:\tools\RDCMan.exe'
    # This script is intentionally standalone (no Common.ps1), so derive the cache directly.
    $cachedExe = Join-Path $PSScriptRoot 'cache\RDCMan-3.12.0.0.exe'

    function Get-RdcManFileVersion {
        param([string]$Path)
        if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
        try { return [version](Get-Item -LiteralPath $Path).VersionInfo.ProductVersion } catch { return $null }
    }

    # Rescue a 3.12 that is still sitting in the sysinternals folder before choco replaces
    # it -- for most hosts that copy is the only 3.12 they will ever have.
    if ((Get-RdcManFileVersion -Path $cachedExe) -ne $pinnedVersion) {
        foreach ($candidate in @($pinnedExe, $sysinternalsExe)) {
            if ((Get-RdcManFileVersion -Path $candidate) -ne $pinnedVersion) { continue }
            try {
                $cacheDir = Split-Path -Parent $cachedExe
                if (-not (Test-Path -LiteralPath $cacheDir)) { New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null }
                Copy-Item -LiteralPath $candidate -Destination $cachedExe -Force -ErrorAction Stop
                Write-LogMessage "Rescued RDCMan $pinnedVersion from $candidate to $cachedExe."
                break
            }
            catch {
                Write-LogMessage "Could not rescue RDCMan $pinnedVersion from $candidate : $_" -Level 'WARNING'
            }
        }
    }

    if ((Get-RdcManFileVersion -Path $pinnedExe) -eq $pinnedVersion) {
        Write-LogMessage "RDCMan $pinnedVersion is installed at $pinnedExe."
        Write-LogMessage 'RDCMan maintenance completed.'
        return
    }

    if ((Get-RdcManFileVersion -Path $cachedExe) -eq $pinnedVersion) {
        try {
            if (-not (Test-Path -LiteralPath $pinnedDir)) { New-Item -Path $pinnedDir -ItemType Directory -Force | Out-Null }
            Copy-Item -LiteralPath $cachedExe -Destination $pinnedExe -Force -ErrorAction Stop
            $now = Get-RdcManFileVersion -Path $pinnedExe
            if ($now -eq $pinnedVersion) { Write-LogMessage "Installed pinned RDCMan $pinnedVersion at $pinnedExe." }
            else { Write-LogMessage "RDCMan install did not take effect (found '$now' at $pinnedExe)." -Level 'WARNING' }
        }
        catch {
            Write-LogMessage "Could not install RDCMan $pinnedVersion from $cachedExe : $_" -Level 'WARNING'
        }
        Write-LogMessage 'RDCMan maintenance completed.'
        return
    }

    $sysVersion = Get-RdcManFileVersion -Path $sysinternalsExe
    if ($sysVersion) {
        Write-LogMessage ("RDCMan $pinnedVersion is not cached; using the sysinternals build $sysVersion at $sysinternalsExe. " +
            "MemLabs will write trusted-certificate entries into the .rdg to suppress its per-VM prompt.")
    }
    else {
        Write-LogMessage "No RDCMan found at $pinnedExe or $sysinternalsExe." -Level 'WARNING'
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

    # Both paths below install the same MSI, and 'upgrade all' runs on its own schedule, so measure for both.
    $installedPwsh = $null
    $availablePwsh = $null
    $pwshMsiWouldFail = $false
    if ($doPs7Upgrade -or $doChocoUpgrade) {
        $installedPwsh = Get-InstalledPwshVersion
        $availablePwsh = Get-ChocoAvailablePackageVersion -PackageId 'pwsh'
        $pwshMsiWouldFail = ($installedPwsh -and $availablePwsh -and $installedPwsh -ge $availablePwsh)
    }

    if ($doPs7Upgrade) {
        if ($pwshMsiWouldFail) {
            # The package MSI returns 1603 when the installed build is newer than the one it carries.
            if ($installedPwsh -gt $availablePwsh) {
                Write-LogMessage "PowerShell $installedPwsh is installed but the Chocolatey pwsh package only offers $availablePwsh (a newer build was installed outside Chocolatey). Skipping the upgrade."
            }
            else {
                Write-LogMessage "PowerShell $installedPwsh is already the latest Chocolatey pwsh version. Skipping the upgrade."
            }

            $now.ToString('o') | Out-File $ps7Flag -Encoding ascii -NoNewline
        }
        else {
            if ($installedPwsh -and $availablePwsh) {
                Write-LogMessage "Upgrading PowerShell 7 ($installedPwsh installed, $availablePwsh available)..."
            }
            else {
                Write-LogMessage 'Upgrading PowerShell 7...'
            }

            & choco upgrade pwsh -y
            $chocoRc = $LASTEXITCODE
            Write-LogMessage "choco upgrade pwsh returned exit code: $chocoRc"

            if (Test-ChocoSuccessCode -Code $chocoRc) {
                $now.ToString('o') | Out-File $ps7Flag -Encoding ascii -NoNewline
                Write-LogMessage 'PowerShell 7 upgrade completed successfully.'
            }
            else {
                $failureMessage = "PowerShell 7 upgrade failed (exit code: $chocoRc)."
                if ($chocoRc -eq 1603 -and $installedPwsh) {
                    $failureMessage += " PowerShell $installedPwsh is already installed; 1603 usually means the package is trying to install an older or equal build."
                }
                Write-LogMessage $failureMessage -Level 'WARNING'
            }
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

        $upgradeAllCommand = '& choco upgrade all -y --ignore-checksums'
        if ($pwshMsiWouldFail) {
            # choco wants the value single-quoted inside the double quotes.
            $upgradeAllCommand += ' --except="''pwsh,powershell-core''"'
            Write-LogMessage "Excluding pwsh and powershell-core from upgrade all; PowerShell $installedPwsh is installed and the package offers $availablePwsh."
        }

        $scriptLines += $upgradeAllCommand
        # 2 is 'nothing to upgrade', returned only when the useEnhancedExitCodes feature is on.
        $scriptLines += 'if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 2 -or $LASTEXITCODE -eq 3010) {'
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

        # Not pwsh: Chocolatey cannot replace pwsh.exe while it is in the parent process chain.
        Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $chocoScriptPath -WindowStyle Normal
        Write-LogMessage 'Chocolatey upgrade all launched in a new window (non-blocking).'
    }
    else {
        Write-LogMessage 'Chocolatey upgrade all skipped (less than 7 days since last run).'
    }

    Write-LogMessage 'Weekly upgrades maintenance completed.'
}

if ($WindowsAdminCenterRemovalOnly) {
    Write-LogMessage '========================================'
    Write-LogMessage 'Windows Admin Center removal worker started'
    Write-LogMessage "Log file: $logFile"
    Write-LogMessage '========================================'

    $workerExitCode = 0
    try {
        Invoke-WindowsAdminCenterRemovalWorker
    }
    catch {
        Write-LogMessage "Windows Admin Center removal threw: $_" -Level 'ERROR'
        $workerExitCode = 1
    }
    finally {
        # Release the lock here rather than trusting liveness alone: a dead PID can be reused, and
        # a stale lock would make every later launch skip the removal.
        Remove-Item -LiteralPath (Join-Path $env:TEMP 'memlabs_wac_removal.pid') -Force -ErrorAction SilentlyContinue
    }

    Write-LogMessage 'Windows Admin Center removal worker completed'
    exit $workerExitCode
}

Write-LogMessage '========================================' 
Write-LogMessage 'Maintenance script started'
Write-LogMessage "Script path: $scriptPath"
Write-LogMessage "Log file: $logFile"
Write-LogMessage '========================================' 

try { Invoke-MemLabsFileAssociationMaintenance } catch { Write-LogMessage "File association maintenance threw: $_" -Level 'ERROR'; $script:MaintenanceHadFailure = $true }
try { Invoke-GitMaintenance } catch { Write-LogMessage "Git maintenance threw: $_" -Level 'ERROR'; $script:MaintenanceHadFailure = $true }
try { Invoke-System32CurlMaintenance } catch { Write-LogMessage "System32 curl maintenance threw: $_" -Level 'ERROR'; $script:MaintenanceHadFailure = $true }
try { Invoke-DotNet6Maintenance } catch { Write-LogMessage ".NET 6 maintenance threw: $_" -Level 'ERROR'; $script:MaintenanceHadFailure = $true }
try { Invoke-WindowsAdminCenterRemoval } catch { Write-LogMessage "Windows Admin Center removal threw: $_" -Level 'ERROR'; $script:MaintenanceHadFailure = $true }
try { Invoke-WindowsTerminalMaintenance } catch { Write-LogMessage "Windows Terminal maintenance threw: $_" -Level 'ERROR'; $script:MaintenanceHadFailure = $true }
try { Invoke-RdcManMaintenance } catch { Write-LogMessage "RDCMan maintenance threw: $_" -Level 'ERROR'; $script:MaintenanceHadFailure = $true }
# Before mRemoteNG: that phase needs 7z.exe to unpack the nightly .rar.
try { Invoke-SevenZipMaintenance } catch { Write-LogMessage "7-Zip maintenance threw: $_" -Level 'ERROR'; $script:MaintenanceHadFailure = $true }
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
