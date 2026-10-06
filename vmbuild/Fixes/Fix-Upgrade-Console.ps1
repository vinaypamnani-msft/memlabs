# Fix-Upgrade-Console: re-runs the Upgrade-Console phase script on top sites
# after deploy so the admin console matches the site version.

$upgradeConsoleSource = Join-Path (Split-Path $PSScriptRoot -Parent) 'DSC\phases\Upgrade-Console.ps1'
$upgradeConsolePayload = ''
if (Test-Path -LiteralPath $upgradeConsoleSource -PathType Leaf) {
    $upgradeConsolePayload = [Convert]::ToBase64String([IO.File]::ReadAllBytes($upgradeConsoleSource))
}

$Fix_UpgradeConsole = {
    param([string]$UpgradeConsolePayload)

    $script = 'C:\staging\DSC\phases\Upgrade-Console.ps1'
    if (-not $UpgradeConsolePayload) {
        return [pscustomobject]@{ Success = $false; Message = 'The host did not provide an Upgrade-Console.ps1 payload' }
    }
    try {
        $scriptDirectory = Split-Path -Parent $script
        if (-not (Test-Path -LiteralPath $scriptDirectory -PathType Container)) {
            [void](New-Item -Path $scriptDirectory -ItemType Directory -Force -ErrorAction Stop)
        }
        [IO.File]::WriteAllBytes($script, [Convert]::FromBase64String($UpgradeConsolePayload))
    }
    catch {
        return [pscustomobject]@{ Success = $false; Message = "Could not refresh Upgrade-Console.ps1 at $script"; Errors = @($_.Exception.Message) }
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
    FixVersion        = "261002.1"
    NeededOnFreshDeploy = $true
    AppliesToExisting   = $true
    AppliesToRoles    = @("Primary", "CAS")
    NotAppliesToRoles = @()
    DependentVMs      = @()
    ScriptBlock       = $Fix_UpgradeConsole
    ArgumentList      = @($upgradeConsolePayload)
}
