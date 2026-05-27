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
        $existing = Get-LocalUser -Name 'Administrator' -ErrorAction Stop
        Write-FixLog "Found local Administrator (SID=$($existing.SID), Enabled=$($existing.Enabled))"

        $secure = ConvertTo-SecureString -String $password -AsPlainText -Force
        Set-LocalUser -Name 'Administrator' -Password $secure -ErrorAction Stop
        Write-FixLog "Password reset via Set-LocalUser" -Level Success

        Enable-LocalUser -Name 'Administrator' -ErrorAction Stop
        $after = Get-LocalUser -Name 'Administrator'
        Write-FixLog "Account enabled (Enabled=$($after.Enabled), PasswordLastSet=$($after.PasswordLastSet))" -Level Success

        [pscustomobject]@{ Success = $true; Message = 'Local Administrator password reset and account enabled' }
    }
    catch {
        Write-FixLog "Exception: $($_.Exception.Message)" -Level Failure
        [pscustomobject]@{ Success = $false; Message = 'Failed to reset local Administrator'; Errors = @($_.Exception.Message) }
    }
}

$fixesToPerform += [PSCustomObject]@{
    FixName           = "Fix_LocalAdminAccount"
    FixVersion        = "240710"
    AppliesToNew      = $true
    AppliesToExisting = $true
    AppliesToRoles    = @()
    NotAppliesToRoles = @("DC", "OSDClient", "AADClient")
    DependentVMs      = @()
    ScriptBlock       = $Fix_LocalAdminAccount
    ArgumentList      = @($Common.LocalAdmin.GetNetworkCredential().Password)
}
