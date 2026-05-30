# Read-DSCLog.ps1 - Opens the latest DSC configuration log via a VSS shadow copy.
# Requires elevation to create shadow copies and symbolic links.

#region Auto-elevate
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {

    # Re-launch from a temp copy so the original file isn't locked by the elevated window
    $tempDir = Join-Path $env:TEMP "Read-DSCLog"
    if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
    $tempScript = Join-Path $tempDir "Read-DSCLog.ps1"
    Copy-Item -Path $PSCommandPath -Destination $tempScript -Force

    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tempScript`""
    exit
}
#endregion

#region Run from temp copy (when already elevated but launched from the original path)
$tempDir = Join-Path $env:TEMP "Read-DSCLog"
$tempScript = Join-Path $tempDir "Read-DSCLog.ps1"
if ($PSCommandPath -ne $tempScript) {
    if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
    Copy-Item -Path $PSCommandPath -Destination $tempScript -Force
    & $tempScript
    exit
}
#endregion

$shadowCopy = $null
$linkPath = 'C:\dsc_logs'

try {
    # Flush NTFS buffers to disk so the shadow copy captures the latest writes
    Write-Host "Flushing file system buffers..." -ForegroundColor Cyan
    $null = fsutil volume flush C: 2>&1

    # Create a VSS shadow copy of C:\
    Write-Host "Creating VSS shadow copy..." -ForegroundColor Cyan
    $wmiClass = Get-WmiObject -List Win32_ShadowCopy -ErrorAction Stop
    $result = $wmiClass.Create("C:\", "ClientAccessible")

    if (-not $result -or $result.ReturnValue -ne 0) {
        $code = if ($result) { $result.ReturnValue } else { "null" }
        throw "Failed to create shadow copy. Return code: $code"
    }

    $shadowCopy = Get-WmiObject Win32_ShadowCopy -ErrorAction Stop |
        Where-Object { $_.ID -eq $result.ShadowID }

    if (-not $shadowCopy) {
        throw "Shadow copy was created but could not be retrieved (ID: $($result.ShadowID))."
    }

    $devicePath = $shadowCopy.DeviceObject + "\"

    # Remove stale symlink if present
    if (Test-Path $linkPath) {
        cmd /c rmdir "$linkPath" 2>$null
    }

    # Create directory symlink into the shadow copy
    $null = cmd /c mklink /d "$linkPath" "$devicePath" 2>&1
    if (-not (Test-Path $linkPath)) {
        throw "Failed to create symbolic link at $linkPath -> $devicePath"
    }

    Start-Sleep -Seconds 1

    # Locate the latest DSC log
    $scpath = Join-Path $linkPath 'Windows\System32\Configuration\ConfigurationStatus'
    if (-not (Test-Path $scpath)) {
        throw "DSC log path not found: $scpath"
    }

    $logfile = Get-ChildItem $scpath -Filter *.json -ErrorAction Stop |
        Sort-Object -Property LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $logfile) {
        throw "No DSC log files (*.json) found in $scpath"
    }

    # Copy the log to temp so notepad doesn't hold the shadow copy open
    $tempLog = Join-Path $env:TEMP $logfile.Name
    Copy-Item -Path $logfile.FullName -Destination $tempLog -Force -ErrorAction Stop

    Write-Host "Opening: $($logfile.Name)" -ForegroundColor Green
    Start-Process notepad.exe -ArgumentList "`"$tempLog`""

    # Brief pause so the copy is fully flushed before cleanup
    Start-Sleep -Seconds 1
}
catch {
    Write-Host "`nERROR: $_" -ForegroundColor Red
    Write-Host "Press any key to exit..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}
finally {
    # Cleanup: remove symlink then delete the shadow copy
    if (Test-Path $linkPath) {
        cmd /c rmdir "$linkPath" 2>$null
    }

    if ($shadowCopy) {
        try { $shadowCopy.Delete() } catch {
            Write-Warning "Failed to delete shadow copy: $_"
        }
    }
}