# Fix-DefenderTuning: cut MsMpEng.exe CPU by excluding the ConfigMgr/SQL/WSUS/
# staging hot paths from real-time scanning and parking the scheduled scans.
# The body lives in C:\staging\Optimize-Defender.ps1 so the base image and the
# fix framework share one implementation.

$Fix_DefenderTuning = {
    $script = "$env:SystemDrive\staging\Optimize-Defender.ps1"
    if (-not (Test-Path -LiteralPath $script)) {
        return [pscustomobject]@{ Success = $false; Message = "$script was not injected"; Errors = @("Missing $script") }
    }
    & $script
}

$fixesToPerform += [PSCustomObject]@{
    FixName             = "Fix-DefenderTuning"
    FixVersion          = "260810"
    NeededOnFreshDeploy = $true
    AppliesToExisting   = $true
    AppliesToRoles      = @()
    NotAppliesToRoles   = @("OSDClient", "AADClient")
    DependentVMs        = @()
    ScriptBlock         = $Fix_DefenderTuning
    InjectFiles         = @("Optimize-Defender.ps1") # must exist in filesToInject\staging dir
}
