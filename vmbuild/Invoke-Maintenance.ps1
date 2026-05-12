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

function Invoke-WeeklyUpgrades {
    Write-LogMessage 'Starting weekly upgrades...'

    if (-not (Test-ChocoAvailable)) {
        Write-LogMessage 'Chocolatey CLI not found. Skipping weekly upgrades.' -Level 'WARNING'
        return
    }

    $ps7Flag = Join-Path $env:TEMP 'memlabs_ps7_upgrade.flag'
    $chocoAllFlag = Join-Path $env:TEMP 'memlabs_choco_all_upgrade.flag'
    $currentWeek = Get-Date -UFormat '%Y-%V'

    Write-LogMessage "Current week: $currentWeek"

    $doPs7Upgrade = $true
    if (Test-Path $ps7Flag) {
        $lastWeek = Get-Content $ps7Flag -ErrorAction SilentlyContinue
        Write-LogMessage "Last PowerShell 7 upgrade week: $lastWeek"
        if ($lastWeek -eq $currentWeek) {
            $doPs7Upgrade = $false
        }
    }

    if ($doPs7Upgrade) {
        Write-LogMessage "Upgrading PowerShell 7 (week $currentWeek)..."
        & choco upgrade pwsh -y
        $chocoRc = $LASTEXITCODE
        Write-LogMessage "choco upgrade pwsh returned exit code: $chocoRc"

        if (Test-ChocoSuccessCode -Code $chocoRc) {
            $currentWeek | Out-File $ps7Flag -Encoding ascii -NoNewline
            Write-LogMessage 'PowerShell 7 upgrade completed successfully.'
        }
        else {
            Write-LogMessage "PowerShell 7 upgrade failed (exit code: $chocoRc)." -Level 'WARNING'
        }
    }
    else {
        Write-LogMessage "PowerShell 7 upgrade skipped (already checked week $currentWeek)."
    }

    $doChocoUpgrade = $true
    if (Test-Path $chocoAllFlag) {
        $lastChocoWeek = Get-Content $chocoAllFlag -ErrorAction SilentlyContinue
        Write-LogMessage "Last Chocolatey upgrade week: $lastChocoWeek"
        if ($lastChocoWeek -eq $currentWeek) {
            $doChocoUpgrade = $false
        }
    }

    if ($doChocoUpgrade) {
        Write-LogMessage "Upgrading all Chocolatey packages (week $currentWeek)..."
        & choco upgrade all -y --ignore-checksums
        $chocoRc = $LASTEXITCODE
        Write-LogMessage "choco upgrade all returned exit code: $chocoRc"

        if (Test-ChocoSuccessCode -Code $chocoRc) {
            $currentWeek | Out-File $chocoAllFlag -Encoding ascii -NoNewline
            Write-LogMessage 'Chocolatey package upgrade completed successfully.'
        }
        else {
            Write-LogMessage "Chocolatey package upgrade failed (exit code: $chocoRc)." -Level 'WARNING'
        }
    }
    else {
        Write-LogMessage "Chocolatey upgrade all skipped (already checked week $currentWeek)."
    }

    Write-LogMessage 'Weekly upgrades maintenance completed.'
}

Write-LogMessage '========================================' 
Write-LogMessage 'Maintenance script started'
Write-LogMessage "Script path: $scriptPath"
Write-LogMessage "Log file: $logFile"
Write-LogMessage '========================================' 

try { Invoke-System32CurlMaintenance } catch { Write-LogMessage "System32 curl maintenance threw: $_" -Level 'ERROR'; $script:MaintenanceHadFailure = $true }
try { Invoke-DotNet6Maintenance } catch { Write-LogMessage ".NET 6 maintenance threw: $_" -Level 'ERROR'; $script:MaintenanceHadFailure = $true }
try { Invoke-WindowsTerminalMaintenance } catch { Write-LogMessage "Windows Terminal maintenance threw: $_" -Level 'ERROR'; $script:MaintenanceHadFailure = $true }
try { Invoke-WeeklyUpgrades } catch { Write-LogMessage "Weekly upgrades threw: $_" -Level 'ERROR'; $script:MaintenanceHadFailure = $true }

Write-LogMessage '========================================' 
Write-LogMessage 'Maintenance script completed'
Write-LogMessage "Log file: $logFile"
Write-LogMessage '========================================' 

if ($script:MaintenanceHadFailure) {
    exit 1
}
exit 0
