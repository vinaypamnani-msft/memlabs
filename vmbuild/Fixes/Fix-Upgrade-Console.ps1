# Fix-Upgrade-Console: re-runs the Upgrade-Console phase script on top sites
# after deploy so the admin console matches the site version.

$Fix_UpgradeConsole = {
    $script = 'C:\staging\DSC\phases\Upgrade-Console.ps1'
    if (-not (Test-Path $script)) {
        return [pscustomobject]@{ Success = $false; Message = "Upgrade-Console.ps1 not found at $script" }
    }
    try {
        $output = @(& $script)
        $result = @($output | Where-Object { $_ -and $_.PSObject.Properties['Success'] }) | Select-Object -Last 1
        if (-not $result) {
            return [pscustomobject]@{ Success = $false; Message = 'Upgrade-Console.ps1 returned no result'; Errors = @($output | ForEach-Object { "$_" }) }
        }
        return $result
    }
    catch {
        [pscustomobject]@{ Success = $false; Message = 'Upgrade-Console.ps1 threw'; Errors = @("$($_.Exception.Message)") }
    }
}

$fixesToPerform += [PSCustomObject]@{
    FixName           = "Fix-Upgrade-Console"
    FixVersion        = "260910.0"
    NeededOnFreshDeploy = $true
    AppliesToExisting   = $true
    AppliesToRoles    = @("Primary", "CAS")
    NotAppliesToRoles = @()
    DependentVMs      = @()
    ScriptBlock       = $Fix_UpgradeConsole
}
