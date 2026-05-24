# Fix-DefaultUserProfile: clear stale IE/Edge WebCache from the default user
# profile so new logons don't inherit a corrupted ESE database.

$Fix_DefaultProfile = {
    $paths = @(
        'C:\Users\Default\AppData\Local\Microsoft\Windows\WebCache',
        'C:\Users\Default\AppData\Local\Microsoft\Windows\INetCache',
        'C:\Users\Default\AppData\Local\Microsoft\Windows\WebCacheLock.dat'
    )
    $removed = 0
    $errs = @()
    foreach ($p in $paths) {
        if (Test-Path $p) {
            try {
                Remove-Item -Path $p -Force -Recurse -ProgressAction SilentlyContinue -ErrorAction Stop | Out-Null
                $removed++
            }
            catch {
                $errs += "Failed to remove ${p}: $($_.Exception.Message)"
            }
        }
    }
    [pscustomobject]@{
        Success = ($errs.Count -eq 0)
        Message = "Removed $removed default-profile cache item(s)"
        Errors  = $errs
    }
}

$fixesToPerform += [PSCustomObject]@{
    FixName           = "Fix-DefaultUserProfile"
    FixVersion        = "211126"
    AppliesToNew      = $true
    AppliesToExisting = $true
    AppliesToRoles    = @()
    NotAppliesToRoles = @("OSDClient", "AADClient")
    DependentVMs      = @()
    ScriptBlock       = $Fix_DefaultProfile
}
