# Fix-PreReq: ensure CAS site has EHTTP forced (IISSSLState) for sub-sites
# that require HTTPS-or-EHTTP communications. Skipped on 2309 and older.

$Fix_Prereq = {
    $SiteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code' -ErrorAction SilentlyContinue
    if (-not $SiteCode) {
        return [pscustomobject]@{ Success = $true; Message = 'No SiteCode in HKLM:\...\SMS\Identification - skipping' }
    }
    $version = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS' -Name 'Full Version' -ErrorAction SilentlyContinue
    if (-not $version) {
        return [pscustomobject]@{ Success = $false; Message = 'No Full Version found in HKLM:\...\SMS' }
    }
    if ([System.Version]$version -lt [System.Version]'5.0.9128') {
        return [pscustomobject]@{ Success = $true; Message = "Version $version is 2309 or older - EHTTP not forced" }
    }

    $NameSpace = "ROOT\SMS\site_$SiteCode"
    # Use WMI (not Get-CimInstance) for SMS_SCI_Component.Put() compatibility.
    $query = "SELECT * FROM SMS_SCI_Component WHERE FileType=2 AND ItemName='SMS_SITE_COMPONENT_MANAGER|SMS Site Server' AND ItemType='Component' AND SiteCode='$SiteCode'"

    # The SMS provider can throw a transient ManagementException (provider busy,
    # or the connection predates a component refresh), and Put() can fail
    # mid-flight. Retry the read-modify-write-verify a few times with backoff,
    # and confirm the change actually persisted by re-reading IISSSLState rather
    # than trusting Put() returning without error.
    $maxAttempts = 4
    $errs = @()
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $component = Get-WmiObject -Namespace $NameSpace -Query $query -ErrorAction Stop
            if (-not $component) {
                $errs += "Attempt ${attempt}: SMS_SCI_Component query returned nothing"
                Write-FixLog $errs[-1] -Level Warning
                if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds (10 * $attempt) }
                continue
            }

            $props = $component.Props
            $index = [Array]::IndexOf($props.PropertyName, 'IISSSLState')
            if ($index -lt 0) {
                $errs += "Attempt ${attempt}: IISSSLState property not found on component"
                Write-FixLog $errs[-1] -Level Warning
                if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds (10 * $attempt) }
                continue
            }
            $value = $props[$index].Value
            $enabled = ($value -band 1024) -eq 1024 -or ($value -eq 63) -or ($value -eq 1472) -or ($value -eq 1504)
            if ($enabled) {
                return [pscustomobject]@{ Success = $true; Message = "IISSSLState $value is already correct (EHTTP forced)" }
            }

            Write-FixLog "Attempt ${attempt}: IISSSLState $value is not correct - updating for EHTTP" -Level Warning
            $props[$index].Value = 1024
            $component.Props = $props
            $component.Put() | Out-Null

            # Verify the write persisted by re-reading the component.
            Start-Sleep -Seconds 3
            $verify = Get-WmiObject -Namespace $NameSpace -Query $query -ErrorAction Stop
            $vProps = $verify.Props
            $vIndex = [Array]::IndexOf($vProps.PropertyName, 'IISSSLState')
            $vValue = $vProps[$vIndex].Value
            $vEnabled = ($vValue -band 1024) -eq 1024 -or ($vValue -eq 63) -or ($vValue -eq 1472) -or ($vValue -eq 1504)
            if ($vEnabled) {
                return [pscustomobject]@{ Success = $true; Message = "IISSSLState updated from $value to $vValue (EHTTP forced, verified attempt $attempt)" }
            }

            $errs += "Attempt ${attempt}: Put() did not persist (read back $vValue)"
            Write-FixLog $errs[-1] -Level Warning
        }
        catch {
            $errs += "Attempt ${attempt}: $($_.Exception.Message)"
            Write-FixLog $errs[-1] -Level Warning
        }
        if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds (10 * $attempt) }
    }

    [pscustomobject]@{ Success = $false; Message = "Failed to force EHTTP (IISSSLState) after $maxAttempts attempts"; Errors = $errs }
}

$fixesToPerform += [PSCustomObject]@{
    FixName           = "Fix-PreReq"
    FixVersion        = "260616.0"
    AppliesToNew      = $false
    AppliesToExisting = $true
    AppliesToRoles    = @("CAS")
    NotAppliesToRoles = @()
    DependentVMs      = @()
    ScriptBlock       = $Fix_Prereq
}
