# Fix_LocalAdminAccount: reset the local Administrator password to the
# Common.LocalAdmin secret and ensure the account is enabled.
#
# NOTE: We marshal the password as a plain string (not [SecureString]) because
# batched maintenance serializes fix ArgumentList via ConvertTo-Json, and a
# SecureString does not round-trip through JSON (becomes {"Length":N}). The
# JSON only lives in memory on the host before being shipped over PSRemoting
# (which is itself encrypted), and the body re-wraps the value in a
# SecureString before handing it to Set-LocalUser.

$Fix_LocalAdminAccount = {
    param ([string]$password)
    try {
        $secure = ConvertTo-SecureString -String $password -AsPlainText -Force
        Set-LocalUser -Name 'Administrator' -Password $secure -ErrorAction Stop
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
    ArgumentList      = @($Common.LocalAdmin.GetNetworkCredential().Password)
}
