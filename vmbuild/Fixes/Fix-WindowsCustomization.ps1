# Portable machine and per-user shell settings shared with OSD policy.

$Fix_WindowsCustomization = {
    $runner = "$env:SystemDrive\staging\Invoke-MemLabsCustomization.ps1"
    if (-not (Test-Path -LiteralPath $runner)) {
        return [pscustomobject]@{ Success = $false; Message = "$runner was not injected"; Errors = @("Missing $runner") }
    }
    $runnerText = [IO.File]::ReadAllText($runner).TrimStart([char]0xFEFF)
    & ([scriptblock]::Create($runnerText)) `
        -Name WindowsMachine, WindowsUserRegistration, WindowsUser `
        -RootPath (Split-Path $runner -Parent) -ContinueOnError
}

$fixesToPerform += [PSCustomObject]@{
    FixName             = 'Fix-WindowsCustomization'
    FixVersion          = '260907.3'
    NeededOnFreshDeploy = $true
    AppliesToExisting   = $true
    AppliesToRoles      = @()
    NotAppliesToRoles   = @()
    DependentVMs        = @()
    ScriptBlock         = $Fix_WindowsCustomization
    InjectFiles         = @(
        'Invoke-MemLabsCustomization.ps1'
        'Set-MemLabsMachineSettings.ps1'
        'Set-MemLabsUserShell.ps1'
    )
}