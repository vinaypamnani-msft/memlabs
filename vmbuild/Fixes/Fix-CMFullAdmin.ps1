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
            -ErrorAction Continue -ErrorVariable NewErr 2>&1
        if ($newOut) { Write-FixLog ($newOut | Out-String).Trim() }
        if ($NewErr) {
            $msg = "New-CMAdministrativeUser attempt $i errors: $($NewErr -join '; ')"
            Write-FixLog $msg -Level Warning
            $errs += $msg
        }
        Start-Sleep -Seconds 15
        $exists = Get-CMAdministrativeUser -RoleName "Full Administrator" -ErrorAction SilentlyContinue |
                  Where-Object { $_.LogonName -like "*$userName*" }
    }
    until ($exists -or $i -gt 5)

    if ($exists) {
        [pscustomobject]@{ Success = $true; Message = "Full Administrator '$domainUserName' is present (verified after $i attempt(s))" }
    }
    else {
        [pscustomobject]@{ Success = $false; Message = "Failed to verify '$domainUserName' as Full Administrator after $i attempts"; Errors = $errs }
    }
}

$fixesToPerform += [PSCustomObject]@{
    FixName           = "Fix-CMFullAdmin"
    FixVersion        = "211127"
    NeededOnFreshDeploy = $false
    AppliesToExisting   = $true
    AppliesToRoles    = @("CASorStandalonePrimary")
    NotAppliesToRoles = @("OSDClient", "AADClient")
    DependentVMs      = @($dc.vmName, $vmNote.remoteSQLVM)
    ScriptBlock       = $Fix_CMFullAdmin
}
