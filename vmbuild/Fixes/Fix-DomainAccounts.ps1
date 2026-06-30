# Fix-DomainAccounts: PasswordNeverExpires + CannotChangePassword for built-in
# domain admin accounts. Runs on the DC; takes the additional account name as
# an argument so domains with custom admin names also get patched.

$Fix_DomainAccount = {
    param ($accountName)
    $accountsToUpdate = @("vmbuildadmin", "administrator", "cm_svc", $accountName) | Select-Object -Unique
    $accountsUpdated = 0
    $errs = @()
    foreach ($account in $accountsToUpdate) {
        $i = 0
        do {
            $i++
            Set-ADUser -Identity $account -PasswordNeverExpires $true -CannotChangePassword $true -ErrorVariable AccountError -ErrorAction SilentlyContinue | Out-Null
            if ($AccountError.Count -ne 0) {
                Write-FixLog "Set-ADUser '$account' attempt $i failed: $($AccountError[0])" -Level Warning
                Start-Sleep -Seconds (5 * $i)
            }
        }
        until ($i -ge 5 -or $AccountError.Count -eq 0)

        if ($AccountError.Count -eq 0) {
            $accountsUpdated++
            Write-FixLog "Updated '$account'" -Level Success
        }
        else {
            $errs += "Failed to update '$account' after $i attempts: $($AccountError[0])"
        }
    }
    [pscustomobject]@{
        Success = ($accountsUpdated -eq $accountsToUpdate.Count)
        Message = "Updated $accountsUpdated of $($accountsToUpdate.Count) accounts"
        Errors  = $errs
    }
}

$fixesToPerform += [PSCustomObject]@{
    FixName           = "Fix-DomainAccounts"
    FixVersion        = "211125.1"
    NeededOnFreshDeploy = $false
    AppliesToExisting   = $true
    AppliesToRoles    = @("DC")
    NotAppliesToRoles = @("OSDClient", "AADClient")
    DependentVMs      = @()
    ScriptBlock       = $Fix_DomainAccount
    ArgumentList      = @($vmNote.adminName)
}
