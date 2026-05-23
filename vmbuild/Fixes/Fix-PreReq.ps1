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
    $component = Get-CimInstance -Namespace $NameSpace -Query "SELECT * FROM SMS_SCI_Component WHERE FileType=2 AND ItemName='SMS_SITE_COMPONENT_MANAGER|SMS Site Server' AND ItemType='Component' AND SiteCode='$SiteCode'" -ErrorAction SilentlyContinue
    if (-not $component) {
        return [pscustomobject]@{ Success = $false; Message = "Could not query SMS_SCI_Component in $NameSpace" }
    }
    # Get-CimInstance returns lazy props; use WMI for SMS_SCI_Component.Put() compatibility
    $component = gwmi -ns $NameSpace -Query "SELECT * FROM SMS_SCI_Component WHERE FileType=2 AND ItemName='SMS_SITE_COMPONENT_MANAGER|SMS Site Server' AND ItemType='Component' AND SiteCode='$SiteCode'"
    $props = $component.Props
    $index = [Array]::IndexOf($props.PropertyName, 'IISSSLState')
    $value = $props[$index].Value
    $enabled = ($value -band 1024) -eq 1024 -or ($value -eq 63) -or ($value -eq 1472) -or ($value -eq 1504)
    if (-not $enabled) {
        Write-FixLog "IISSSLState $value is not correct - updating for EHTTP" -Level Warning
        $props[$index].Value = 1024
        $component.Props = $props
        $component.Put() | Out-Null
        [pscustomobject]@{ Success = $true; Message = "IISSSLState updated from $value to 1024 (EHTTP forced)" }
    }
    else {
        [pscustomobject]@{ Success = $true; Message = "IISSSLState $value is already correct" }
    }
}

$fixesToPerform += [PSCustomObject]@{
    FixName           = "Fix-PreReq"
    FixVersion        = "250116.0"
    AppliesToNew      = $false
    AppliesToExisting = $true
    AppliesToRoles    = @("CAS")
    NotAppliesToRoles = @()
    DependentVMs      = @()
    ScriptBlock       = $Fix_Prereq
}
