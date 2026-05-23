# Fix-Upgrade-Console: re-runs the Upgrade-Console phase script on top sites
# after deploy so the admin console matches the site version.

$Fix_UpgradeConsole = {
    $script = 'C:\staging\DSC\phases\Upgrade-Console.ps1'
    if (-not (Test-Path $script)) {
        return [pscustomobject]@{ Success = $false; Message = "Upgrade-Console.ps1 not found at $script" }
    }
    try {
        & $script
        [pscustomobject]@{ Success = $true; Message = 'Upgrade-Console.ps1 completed' }
    }
    catch {
        [pscustomobject]@{ Success = $false; Message = 'Upgrade-Console.ps1 threw'; Errors = @("$($_.Exception.Message)") }
    }
}

$fixesToPerform += [PSCustomObject]@{
    FixName           = "Fix-Upgrade-Console"
    FixVersion        = "250107.0"
    AppliesToNew      = $true
    AppliesToExisting = $false
    AppliesToRoles    = @("Primary", "CAS")
    NotAppliesToRoles = @()
    DependentVMs      = @()
    ScriptBlock       = $Fix_UpgradeConsole
}
