[CmdletBinding()]
param ()

$ErrorActionPreference = 'Continue'

function Test-ChocoSuccessCode {
    param (
        [int]$Code
    )

    return ($Code -eq 0 -or $Code -eq 1641 -or $Code -eq 3010)
}

function Invoke-System32CurlMaintenance {
    $system32Curl = Join-Path $env:WINDIR 'System32\curl.exe'
    $chocoCurlShim = 'C:\ProgramData\chocolatey\bin\curl.exe'

    if (-not (Test-Path $system32Curl)) {
        return
    }

    Write-Host "System32 curl detected at '$system32Curl'."

    if (-not (Test-Path $chocoCurlShim)) {
        Write-Host "Chocolatey curl shim not found at '$chocoCurlShim'. Skipping uninstall."
        return
    }

    Write-Host 'Removing Chocolatey curl package to avoid non-System32 curl usage...'
    & choco uninstall curl -y | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'WARNING: First curl uninstall attempt failed. Retrying...'
        & choco uninstall curl -y | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'WARNING: curl uninstall retry failed.'
        }
    }
}

function Invoke-DotNet6Maintenance {
    $dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnetCommand) {
        Write-Host '.NET CLI not found. Skipping .NET 6 detection/removal.'
        return
    }

    $dotnet6Found = $false
    $runtimeMatches = & $dotnetCommand.Source --list-runtimes 2>$null | Select-String -Pattern ' 6\.[0-9]'
    $sdkMatches = & $dotnetCommand.Source --list-sdks 2>$null | Select-String -Pattern '^6\.[0-9]'

    if ($runtimeMatches -or $sdkMatches) {
        $dotnet6Found = $true
    }

    if (-not $dotnet6Found) {
        Write-Host '.NET 6 not detected. Skipping .NET 6 removal.'
        return
    }

    Write-Host '.NET 6 detected. Attempting uninstall using registered Windows uninstall entries...'

    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $items = @()
    foreach ($path in $paths) {
        $items += @(Get-ItemProperty -Path $path -ErrorAction SilentlyContinue)
    }

    $targets = foreach ($item in $items) {
        if ($item.DisplayName -and $item.DisplayVersion -and $item.DisplayVersion -like '6.*') {
            if (
                $item.DisplayName -like 'Microsoft .NET*' -or
                $item.DisplayName -like 'Microsoft ASP.NET Core*' -or
                $item.DisplayName -like 'Microsoft Windows Desktop Runtime*'
            ) {
                $item
            }
        }
    }

    $hadFailure = $false
    foreach ($target in $targets) {
        $uninstall = $target.QuietUninstallString
        if (-not $uninstall) {
            $uninstall = $target.UninstallString
        }

        if ([string]::IsNullOrWhiteSpace($uninstall)) {
            continue
        }

        if ($uninstall -match 'msiexec') {
            if ($uninstall -match '(/i|/I)') {
                $uninstall = $uninstall -replace '(/i|/I)', '/x'
            }
            if ($uninstall -notmatch '(/qn|/quiet)') {
                $uninstall += ' /qn'
            }
            if ($uninstall -notmatch '/norestart') {
                $uninstall += ' /norestart'
            }
        }
        else {
            if ($uninstall -notmatch '(/qn|/quiet)') {
                $uninstall += ' /quiet'
            }
            if ($uninstall -notmatch '/norestart') {
                $uninstall += ' /norestart'
            }
        }

        $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $uninstall -Wait -PassThru -WindowStyle Hidden
        if ($proc.ExitCode -ne 0) {
            $hadFailure = $true
        }
    }

    if ($hadFailure) {
        Write-Host 'WARNING: One or more .NET 6 uninstall operations failed.'
    }
}

function Invoke-WindowsTerminalMaintenance {
    $wtFound = $null -ne (Get-Command wt.exe -ErrorAction SilentlyContinue)

    if ($wtFound) {
        return
    }

    Write-Host 'Windows Terminal not installed, attempting to install...'
    & choco install microsoft-ui-xaml -y | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'WARNING: Failed to install microsoft-ui-xaml.'
    }

    & choco install microsoft-windows-terminal -y | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'WARNING: Failed to install Windows Terminal.'
    }
}

function Invoke-WeeklyUpgrades {
    $ps7Flag = Join-Path $env:TEMP 'memlabs_ps7_upgrade.flag'
    $chocoAllFlag = Join-Path $env:TEMP 'memlabs_choco_all_upgrade.flag'
    $currentWeek = Get-Date -UFormat '%Y-%V'

    $doPs7Upgrade = $true
    if (Test-Path $ps7Flag) {
        $lastWeek = Get-Content $ps7Flag -ErrorAction SilentlyContinue
        if ($lastWeek -eq $currentWeek) {
            $doPs7Upgrade = $false
        }
    }

    if ($doPs7Upgrade) {
        Write-Host "Upgrading PowerShell 7 (week $currentWeek)..."
        & choco upgrade pwsh -y
        $chocoRc = $LASTEXITCODE
        if (Test-ChocoSuccessCode -Code $chocoRc) {
            $currentWeek | Out-File $ps7Flag -Encoding ascii -NoNewline
        }
        else {
            Write-Host "WARNING: Failed to upgrade PowerShell 7 (exit $chocoRc)."
        }
    }
    else {
        Write-Host "PowerShell 7 upgrade skipped (already checked week $currentWeek)."
    }

    $doChocoUpgrade = $true
    if (Test-Path $chocoAllFlag) {
        $lastChocoWeek = Get-Content $chocoAllFlag -ErrorAction SilentlyContinue
        if ($lastChocoWeek -eq $currentWeek) {
            $doChocoUpgrade = $false
        }
    }

    if ($doChocoUpgrade) {
        Write-Host "Upgrading all Chocolatey packages (week $currentWeek)..."
        & choco upgrade all -y --ignore-checksums
        $chocoRc = $LASTEXITCODE
        if (Test-ChocoSuccessCode -Code $chocoRc) {
            $currentWeek | Out-File $chocoAllFlag -Encoding ascii -NoNewline
        }
        else {
            Write-Host "WARNING: choco upgrade all failed (exit $chocoRc)."
        }
    }
    else {
        Write-Host "Chocolatey upgrade all skipped (already checked week $currentWeek)."
    }
}

Invoke-System32CurlMaintenance
Invoke-DotNet6Maintenance
Invoke-WindowsTerminalMaintenance
Invoke-WeeklyUpgrades
