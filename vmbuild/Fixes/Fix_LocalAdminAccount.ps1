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
        $existing = @(Get-LocalUser -ErrorAction Stop | Where-Object { $_.SID.Value -match '-500$' })
        if ($existing.Count -ne 1) { throw "Expected one built-in local administrator account with RID 500, found $($existing.Count)." }
        $administratorSid = $existing[0].SID
        Write-FixLog "Found built-in local administrator '$($existing[0].Name)' (SID=$administratorSid, Enabled=$($existing[0].Enabled))"

        $secure = ConvertTo-SecureString -String $password -AsPlainText -Force
        Set-LocalUser -SID $administratorSid -Password $secure -ErrorAction Stop
        Write-FixLog "Password reset via Set-LocalUser" -Level Success

        Enable-LocalUser -SID $administratorSid -ErrorAction Stop
        $after = Get-LocalUser -SID $administratorSid
        Write-FixLog "Account enabled (Enabled=$($after.Enabled), PasswordLastSet=$($after.PasswordLastSet))" -Level Success

        [pscustomobject]@{ Success = $true; Message = 'Local Administrator password reset and account enabled' }
    }
    catch {
        Write-FixLog "Exception: $($_.Exception.Message)" -Level Failure
        [pscustomobject]@{ Success = $false; Message = 'Failed to reset local Administrator'; Errors = @($_.Exception.Message) }
    }
}

# Defense-in-depth: Initialize-Storage now fails fast (Common.ps1) when the
# vmbuildadmin credential can't be obtained, so $Common.LocalAdmin should never be
# $null by the time maintenance runs. This guard is the second layer: the
# ArgumentList below is evaluated at descriptor-load time (when Get-VMFixes
# dot-sources every Fix*.ps1), so a bare $Common.LocalAdmin.GetNetworkCredential()
# on a null LocalAdmin would throw "You cannot call a method on a null-valued
# expression" and abort the ENTIRE fix sweep -- not just this fix. Skip
# registering this fix instead; it is idempotent and re-applies once creds load.
if ($null -ne $Common.LocalAdmin) {
    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix_LocalAdminAccount"
        FixVersion        = "260911"
        NeededOnFreshDeploy = $true
        AppliesToExisting   = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @("DC", "OSDClient", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_LocalAdminAccount
        ArgumentList      = @($Common.LocalAdmin.GetNetworkCredential().Password)
    }
}
else {
    Write-Log "Fix_LocalAdminAccount: `$Common.LocalAdmin is null (storage/credential init incomplete); skipping this fix this pass." -Warning
}
