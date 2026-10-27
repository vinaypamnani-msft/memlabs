# Fix-LocalAccount: PasswordNeverExpires on the local vmbuildadmin account.

$Fix_LocalAccount = {
    Set-LocalUser -Name 'vmbuildadmin' -PasswordNeverExpires $true -ErrorAction SilentlyContinue -ErrorVariable AccountError
    if ($AccountError.Count -eq 0) {
        [pscustomobject]@{ Success = $true; Message = "vmbuildadmin PasswordNeverExpires set" }
    }
    else {
        [pscustomobject]@{
            Success = $false
            Message = 'Set-LocalUser failed for vmbuildadmin'
            Errors  = @($AccountError | ForEach-Object { $_.ToString() })
        }
    }
}

$fixesToPerform += [PSCustomObject]@{
    FixName           = "Fix-LocalAccount"
    FixVersion        = "211125.2"
    NeededOnFreshDeploy = $false
    AppliesToExisting   = $true
    AppliesToRoles    = @()
    NotAppliesToRoles = @("DC", "OSDClient", "AADClient")
    DependentVMs      = @()
    ScriptBlock       = $Fix_LocalAccount
}
