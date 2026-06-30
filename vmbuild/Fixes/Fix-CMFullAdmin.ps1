# Fix-CMFullAdmin: ensure vmbuildadmin is a Full Administrator in the local
# ConfigMgr site so admin console + sqlcmd-via-CM provider both work.

$Fix_CMFullAdmin = {
    $SiteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code' -ErrorVariable ErrVar -ErrorAction SilentlyContinue
    if ($ErrVar.Count -ne 0 -or [string]::IsNullOrWhiteSpace($SiteCode)) {
        return [pscustomobject]@{ Success = $true; Message = 'No site code; CM not installed or uninstalled - skipping' }
    }

    # Use DNS domain (USERDNSDOMAIN) instead of bare USERDOMAIN; SMS Provider needs FQDN.
    $dnsDomain = $env:USERDNSDOMAIN
    if ([string]::IsNullOrWhiteSpace($dnsDomain)) {
        return [pscustomobject]@{ Success = $false; Message = 'USERDNSDOMAIN is empty; cannot build SMS Provider FQDN' }
    }
    $ProviderMachineName = "$env:COMPUTERNAME.$dnsDomain"
    Write-FixLog "SiteCode=$SiteCode Provider=$ProviderMachineName"

    # Get CM module path
    $key = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32)
    $subKey = $key.OpenSubKey("SOFTWARE\Microsoft\ConfigMgr10\Setup")
    if (-not $subKey) {
        return [pscustomobject]@{ Success = $true; Message = 'CM admin console not installed - skipping' }
    }
    $uiInstallPath = $subKey.GetValue("UI Installation Directory")
    $modulePath = $uiInstallPath + "bin\ConfigurationManager.psd1"
    $initParams = @{}

    $userName = "vmbuildadmin"
    $userDomain = $env:USERDOMAIN
    $domainUserName = "$userDomain\$userName"
    $errs = @()

    $i = 0
    do {
        $i++
        # The entire provider interaction is wrapped in try/catch because the CM
        # cmdlets here (New-PSDrive CMSite, Get-/New-CMAdministrativeUser) raise
        # TERMINATING errors that -ErrorAction Continue does NOT suppress. The most
        # common one, "No object corresponds to the specified parameters.", is thrown
        # by New-CMAdministrativeUser while the SMS Provider is still warming up (the
        # existence check on the first attempt can take minutes against a cold
        # provider). Without this try/catch that terminating error escapes the whole
        # do/until loop, so the fix body aborts on attempt 1 and the intended 5-attempt
        # /15s-backoff retry NEVER runs -- and because this fix runs on the CAS, that
        # single failure aborts the entire maintenance phase ("CAS failed. Stopping
        # Phase."). Catching it lets the loop actually retry and give the provider time
        # to settle.
        try {
            if ($null -eq (Get-Module ConfigurationManager)) {
                Import-Module $modulePath -ErrorAction SilentlyContinue | Out-Null
            }
            New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams -ErrorAction SilentlyContinue | Out-Null
            $waits = 0
            while ($null -eq (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $waits++
                if ($waits -gt 6) {
                    $errs += "Could not create CMSite PSDrive '$SiteCode' against '$ProviderMachineName' after 60s"
                    return [pscustomobject]@{ Success = $false; Message = 'CMSite PSDrive never came online'; Errors = $errs }
                }
                Start-Sleep -Seconds 10
                New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams -ErrorAction SilentlyContinue | Out-Null
            }
            Set-Location "$($SiteCode):\" @initParams | Out-Null

            $exists = Get-CMAdministrativeUser -RoleName "Full Administrator" -ErrorAction SilentlyContinue |
                      Where-Object { $_.LogonName -like "*$userName*" }
            if ($exists) { break }

            Write-FixLog "Attempt $i`: Adding $domainUserName as Full Administrator"
            $newOut = New-CMAdministrativeUser -Name $domainUserName -RoleName "Full Administrator" `
                -SecurityScopeName "All", "All Systems", "All Users and User Groups" `
                -ErrorAction Stop 2>&1
            if ($newOut) { Write-FixLog ($newOut | Out-String).Trim() }
        }
        catch {
            $msg = "New-CMAdministrativeUser attempt $i error (will retry): $($_.Exception.Message)"
            Write-FixLog $msg -Level Warning
            $errs += $msg
        }

        Start-Sleep -Seconds 15
        try {
            $exists = Get-CMAdministrativeUser -RoleName "Full Administrator" -ErrorAction SilentlyContinue |
                      Where-Object { $_.LogonName -like "*$userName*" }
        }
        catch {
            $exists = $null
        }
    }
    until ($exists -or $i -gt 5)

    if ($exists) {
        [pscustomobject]@{ Success = $true; Message = "Full Administrator '$domainUserName' is present (verified after $i attempt(s))" }
    }
    else {
        # Final-failure diagnostics: capture everything needed to tell "SMS Provider
        # not ready / can't resolve the account" from "account genuinely missing in
        # AD", straight from the build log -- without needing access to the box.
        # All best-effort; never throw here. Each line is BOTH written to the fix
        # transcript (Write-FixLog -> pulled by Get-VMFixTranscript) AND returned in
        # Errors[] (logged by the maintenance harness as "[Fix-CMFullAdmin] ERROR: ...").
        $diag = @()
        $diag += "DIAG Provider=$ProviderMachineName SiteCode=$SiteCode Account=$domainUserName (added as '$userName' in domain '$userDomain')"
        try {
            $drive = Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue
            $diag += "DIAG CMSite PSDrive online: $([bool]$drive)"
        }
        catch { $diag += "DIAG CMSite PSDrive probe threw: $($_.Exception.Message)" }
        try {
            $current = @(Get-CMAdministrativeUser -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty LogonName -ErrorAction SilentlyContinue)
            if ($current.Count -gt 0) {
                $diag += "DIAG SMS Provider answered; existing administrative users ($($current.Count)): $($current -join ', ')"
            }
            else {
                $diag += "DIAG Get-CMAdministrativeUser returned no users (SMS Provider may not be answering yet)"
            }
        }
        catch { $diag += "DIAG Get-CMAdministrativeUser threw: $($_.Exception.Message)" }
        try {
            $searcher = [ADSISearcher]"(&(objectCategory=person)(objectClass=user)(sAMAccountName=$userName))"
            $adHit = $searcher.FindOne()
            $diag += "DIAG AD resolves account '$userName': $([bool]$adHit)$(if ($adHit) { " ($($adHit.Properties['distinguishedname'][0]))" })"
        }
        catch { $diag += "DIAG AD lookup of '$userName' threw: $($_.Exception.Message)" }
        foreach ($d in $diag) { Write-FixLog $d -Level Warning }

        [pscustomobject]@{
            Success = $false
            Message = "Failed to verify '$domainUserName' as Full Administrator after $i attempts"
            Errors  = @($errs + $diag)
        }
    }
}

$fixesToPerform += [PSCustomObject]@{
    FixName           = "Fix-CMFullAdmin"
    FixVersion        = "260630"
    NeededOnFreshDeploy = $false
    AppliesToExisting   = $true
    AppliesToRoles    = @("CASorStandalonePrimary")
    NotAppliesToRoles = @("OSDClient", "AADClient")
    DependentVMs      = @($dc.vmName, $vmNote.remoteSQLVM)
    ScriptBlock       = $Fix_CMFullAdmin
}
