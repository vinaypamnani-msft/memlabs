# Fix_LocalAdminAccount: reset the local Administrator password to the
# Common.LocalAdmin secret and ensure the account is enabled.

$Fix_LocalAdminAccount = {
    param ([SecureString]$password)
    try {
        Set-LocalUser -Name 'Administrator' -Password $password -ErrorAction Stop
        Enable-LocalUser -Name 'Administrator' -ErrorAction Stop
        [pscustomobject]@{ Success = $true; Message = 'Local Administrator password reset and account enabled' }
    }
    catch {
        [pscustomobject]@{ Success = $false; Message = 'Failed to reset local Administrator'; Errors = @($_.Exception.Message) }
    }
}

$fixesToPerform += [PSCustomObject]@{
    FixName           = "Fix_LocalAdminAccount"
    FixVersion        = "240710"
    AppliesToNew      = $true
    AppliesToExisting = $true
    AppliesToRoles    = @()
    NotAppliesToRoles = @("DC", "OSDClient", "Linux", "AADClient")
    DependentVMs      = @()
    ScriptBlock       = $Fix_LocalAdminAccount
    ArgumentList      = @($Common.LocalAdmin.Password)
}
