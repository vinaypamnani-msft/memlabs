# Fix-DefenderTuning: cut MsMpEng.exe CPU by excluding the ConfigMgr/SQL/WSUS/
# staging hot paths from real-time scanning and parking the scheduled scans.
# The body lives in C:\staging\Optimize-Defender.ps1 so the base image and the
# fix framework share one implementation.

$Fix_DefenderTuning = {
    $runner = "$env:SystemDrive\staging\Invoke-MemLabsCustomization.ps1"
    if (-not (Test-Path -LiteralPath $runner)) {
        return [pscustomobject]@{ Success = $false; Message = "$runner was not injected"; Errors = @("Missing $runner") }
    }
    $runnerText = [IO.File]::ReadAllText($runner).TrimStart([char]0xFEFF)
    & ([scriptblock]::Create($runnerText)) -Name DefenderTuning -RootPath (Split-Path $runner -Parent)
}

$fixesToPerform += [PSCustomObject]@{
    FixName             = "Fix-DefenderTuning"
    FixVersion          = "260907.1"
    NeededOnFreshDeploy = $true
    AppliesToExisting   = $true
    AppliesToRoles      = @()
    NotAppliesToRoles   = @("AADClient")
    DependentVMs        = @()
    ScriptBlock         = $Fix_DefenderTuning
    InjectFiles         = @("Invoke-MemLabsCustomization.ps1", "Optimize-Defender.ps1")
}
